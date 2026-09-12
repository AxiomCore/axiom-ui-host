package com.axiom.uihost;

import android.app.Activity;
import android.database.ContentObserver;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Base64;
import android.util.Log;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import com.lynx.tasm.LynxError;
import com.lynx.tasm.LynxView;
import com.lynx.tasm.LynxViewBuilder;
import com.lynx.tasm.LynxViewClient;
import com.lynx.xelement.XElementBehaviors;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * A fixed-name, app-private development-bundle receiver. The CLI copies a
 * bundle and revision record through adb run-as; this process never accepts a
 * path, URL, or command supplied by renderer JavaScript.
 */
public final class AxiomHostActivity extends Activity {
  private static final String TAG = "AxiomUIHost";
  private static final String BUNDLE = "axiom.app.lynx.bundle";
  private static final String REVISION = "axiom.app.revision.json";
  private static final String ACK = "axiom.app.ack.json";
  private static final String DIAGNOSTIC = "axiom.app.diagnostic.json";
  private final Handler handler = new Handler(Looper.getMainLooper());
  private LynxView lynxView;
  private String seenRevision = "";
  private long activeSequence = 0;
  private String activeGraphRevision = "";
  private long diagnosticSequence = 0;
  private final ContentObserver animationScaleObserver = new ContentObserver(handler) {
    @Override public void onChange(boolean selfChange) {
      if (lynxView != null) lynxView.updateGlobalProps(axiomGlobalProps());
    }
  };

  private Map<String, Object> axiomGlobalProps() {
    Map<String, Object> props = new HashMap<>();
    float animatorScale = 1.0f;
    try {
      animatorScale = Settings.Global.getFloat(
          getContentResolver(), Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f);
    } catch (RuntimeException ignored) {
      // A missing setting is the platform default: motion is enabled.
    }
    props.put("reduceMotion", animatorScale == 0.0f);
    return props;
  }

  private final Runnable watchRevision = new Runnable() {
    @Override public void run() {
      try { applyRevisionIfNeeded(); }
      catch (Exception error) { Log.e(TAG, "cannot apply Axiom development bundle", error); }
      handler.postDelayed(this, 150);
    }
  };

  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    LynxViewBuilder builder = new LynxViewBuilder();
    // XElement's generated registry is part of the host binary. This is not a
    // dynamic plugin path: the pinned implementations are compiled, signed,
    // and released with the Axiom UI Host.
    builder.addBehaviors(new XElementBehaviors().create());
    lynxView = new LynxView(this, builder);
    lynxView.addLynxViewClient(new LynxViewClient() {
      @Override public void onReceivedError(LynxError error) {
        publishDiagnostic(error);
      }
    });
    setContentView(lynxView, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    getContentResolver().registerContentObserver(
        Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
        false,
        animationScaleObserver);
    handler.post(watchRevision);
  }

  @Override protected void onDestroy() {
    handler.removeCallbacks(watchRevision);
    getContentResolver().unregisterContentObserver(animationScaleObserver);
    if (lynxView != null) {
      lynxView.onEnterBackground();
      lynxView.destroy();
      lynxView = null;
    }
    super.onDestroy();
  }

  @Override protected void onResume() {
    super.onResume();
    if (lynxView != null) lynxView.onEnterForeground();
  }

  @Override protected void onPause() {
    if (lynxView != null) lynxView.onEnterBackground();
    super.onPause();
  }

  private File support() {
    File root = new File(getFilesDir(), "axiom-ui-host");
    if (!root.exists() && !root.mkdirs()) throw new IllegalStateException("cannot create host support directory");
    return root;
  }

  private void applyRevisionIfNeeded() throws Exception {
    File revisionFile = new File(support(), REVISION);
    File bundleFile = new File(support(), BUNDLE);
    if (!revisionFile.isFile() || !bundleFile.isFile()) return;
    JSONObject revision = new JSONObject(readUtf8(revisionFile));
    if (!"axiom-ui-host-revision/v2".equals(revision.optString("format"))) return;
    String graph = revision.optString("graphRevision");
    long sequence = revision.optLong("sequence", 0);
    if (sequence <= 0 || graph.length() == 0) return;
    String identity = sequence + ":" + graph;
    if (identity.equals(seenRevision)) return;
    byte[] bundle = readBytes(bundleFile);
    if (!sha256(bundle).equals(revision.optString("bundleSha256"))) {
      writeAck(sequence, graph, "rejected_last_good", "bundle checksum mismatch");
      seenRevision = identity;
      return;
    }
    activeSequence = sequence;
    activeGraphRevision = graph;
    File staleDiagnostic = new File(support(), DIAGNOSTIC);
    if (staleDiagnostic.isFile() && !staleDiagnostic.delete()) {
      Log.w(TAG, "cannot clear stale Lynx diagnostic");
    }
    // Lynx's public byte-template API replaces the page template. A future
    // renderer patch API may acknowledge preserved state, but until it has
    // Android E2E evidence this host reports an honest reset fallback.
    // The new template creates a fresh facade whose request IDs restart at 1.
    // Drain the previous generation before replacement so no late callback can
    // be mistaken for a response owned by the new page.
    AxiomRuntimeModule.nativeResetSession();
    lynxView.updateGlobalProps(axiomGlobalProps());
    lynxView.renderTemplate(bundle, Collections.<String, Object>emptyMap());
    String requested = revision.optString("deliveryMode");
    String reason = "state_preserving_patch".equals(requested)
        ? "Android host currently applies a full template reload"
        : revision.optString("fallbackReason", "native template reload");
    writeAck(sequence, graph, "applied_state_reset", reason);
    seenRevision = identity;
  }

  private synchronized void publishDiagnostic(LynxError error) {
    if (activeSequence <= 0 || activeGraphRevision.length() == 0) return;
    try {
      JSONObject diagnostic = new JSONObject();
      diagnostic.put("id", ++diagnosticSequence);
      diagnostic.put("sequence", activeSequence);
      diagnostic.put("graphRevision", activeGraphRevision);
      diagnostic.put("severity", LynxError.LEVEL_WARN.equals(error.getLevel()) ? "warning" : "error");
      diagnostic.put("code", "LYNX_" + error.getSubCode());
      diagnostic.put("message", error.getSummaryMessage());
      diagnostic.put("suggestion", error.getFixSuggestion());
      File destination = new File(support(), DIAGNOSTIC);
      JSONObject envelope = destination.isFile()
          ? new JSONObject(readUtf8(destination))
          : new JSONObject();
      if (!"axiom-ui-host-diagnostics/v1".equals(envelope.optString("format"))) {
        envelope = new JSONObject();
        envelope.put("format", "axiom-ui-host-diagnostics/v1");
        envelope.put("diagnostics", new JSONArray());
      }
      JSONArray diagnostics = envelope.getJSONArray("diagnostics");
      diagnostics.put(diagnostic);
      while (diagnostics.length() > 50) diagnostics.remove(0);
      atomicWrite(destination, envelope.toString().getBytes(StandardCharsets.UTF_8));
    } catch (Exception failure) {
      Log.e(TAG, "cannot publish Lynx diagnostic", failure);
    }
  }

  private void writeAck(long sequence, String graph, String status, String reason) throws Exception {
    JSONObject ack = new JSONObject();
    ack.put("format", "axiom-ui-host-ack/v2");
    ack.put("sequence", sequence);
    ack.put("graphRevision", graph);
    ack.put("status", status);
    ack.put("reason", reason);
    atomicWrite(new File(support(), ACK), ack.toString().getBytes(StandardCharsets.UTF_8));
  }

  private static byte[] readBytes(File file) throws Exception {
    FileInputStream input = new FileInputStream(file);
    try { byte[] result = new byte[(int) file.length()]; int at = 0, read;
      while (at < result.length && (read = input.read(result, at, result.length - at)) > 0) at += read;
      if (at != result.length) throw new IllegalStateException("short bundle read"); return result;
    } finally { input.close(); }
  }
  private static String readUtf8(File file) throws Exception { return new String(readBytes(file), StandardCharsets.UTF_8); }
  private static void atomicWrite(File destination, byte[] bytes) throws Exception {
    File tmp = new File(destination.getParentFile(), destination.getName() + ".tmp");
    FileOutputStream output = new FileOutputStream(tmp); try { output.write(bytes); output.getFD().sync(); } finally { output.close(); }
    if (!tmp.renameTo(destination)) throw new IllegalStateException("cannot replace acknowledgement");
  }
  private static String sha256(byte[] bytes) throws Exception {
    byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes); StringBuilder result = new StringBuilder();
    for (byte value : digest) result.append(String.format("%02x", value & 0xff)); return result.toString();
  }
}
