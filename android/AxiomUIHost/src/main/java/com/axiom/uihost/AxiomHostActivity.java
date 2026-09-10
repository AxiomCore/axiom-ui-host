package com.axiom.uihost;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import com.lynx.tasm.LynxView;
import com.lynx.tasm.LynxViewBuilder;
import com.lynx.tasm.behavior.Behavior;
import com.lynx.tasm.behavior.LynxContext;
import com.lynx.tasm.behavior.shadow.ShadowNode;
import com.lynx.tasm.behavior.ui.LynxUI;
import com.lynx.xelement.input.LynxUIInput;
import com.lynx.xelement.input.LynxUIInputShadowNode;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Collections;
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
  private final Handler handler = new Handler(Looper.getMainLooper());
  private LynxView lynxView;
  private String seenRevision = "";

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
    // Keep Axiom's native primitive surface explicit. Pulling the aggregate
    // XElement registry would link every optional XElement component merely
    // to support Input.
    builder.addBehavior(new Behavior("input", false, false, false) {
      @Override public LynxUI createUIWithParams(LynxContext context, Object params) {
        return new LynxUIInput(context, params);
      }

      @Override public ShadowNode createShadowNode() {
        return new LynxUIInputShadowNode();
      }
    });
    lynxView = new LynxView(this, builder);
    setContentView(lynxView, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    handler.post(watchRevision);
  }

  @Override protected void onDestroy() { handler.removeCallbacks(watchRevision); super.onDestroy(); }

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
    // Lynx's public byte-template API replaces the page template. A future
    // renderer patch API may acknowledge preserved state, but until it has
    // Android E2E evidence this host reports an honest reset fallback.
    lynxView.renderTemplate(bundle, Collections.<String, Object>emptyMap());
    String requested = revision.optString("deliveryMode");
    String reason = "state_preserving_patch".equals(requested)
        ? "Android host currently applies a full template reload"
        : revision.optString("fallbackReason", "native template reload");
    writeAck(sequence, graph, "applied_state_reset", reason);
    seenRevision = identity;
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
