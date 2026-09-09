package com.axiom.uihost;

import android.content.Context;
import android.util.Base64;
import com.lynx.react.bridge.Callback;
import com.lynx.jsbridge.LynxMethod;
import com.lynx.jsbridge.LynxModule;
import java.io.File;
import java.util.HashMap;
import java.util.Map;

/**
 * Narrow Android counterpart of the iOS Axiom bridge. Renderer code receives
 * only typed contract operations; Rust remains behind the stable C/JNI ABI.
 */
public final class AxiomRuntimeModule extends LynxModule {
  private static final int FACADE_PROTOCOL_VERSION = 1;
  private static final int MODULE_VERSION = 1;

  static {
    System.loadLibrary("axiom_runtime_jni");
  }

  public AxiomRuntimeModule(Context context) { super(context); }

  @LynxMethod
  public Map<String, Object> runtimeInfo() {
    Map<String, Object> result = new HashMap<>();
    result.put("moduleVersion", MODULE_VERSION);
    result.put("runtimeAbiVersion", nativeAbiVersion());
    result.put("target", "android");
    // Lynx Callback is single-shot on Android.  Streaming uses a separate
    // event channel only after its adapter has conformance evidence.
    result.put("capabilities", new String[] {"query", "mutation", "cancel"});
    return result;
  }

  @LynxMethod
  public Map<String, Object> initialize(Map<String, Object> config) {
    Map<String, Object> result = status(0, null);
    if (config == null || number(config.get("protocolVersion")) != FACADE_PROTOCOL_VERSION) {
      return status(2, "AXIOM_UI_RUNTIME_CONFIG: facade protocol 1 is required.");
    }
    // The pinned LynxModule API exposes its Context through protected mContext;
    // newer getContext() accessors are not available in this engine revision.
    File root = new File(mContext.getFilesDir(), "axiom-ui-host");
    if (!root.exists() && !root.mkdirs()) return status(2, "AXIOM_UI_RUNTIME_INIT: cannot create runtime storage.");
    int value = nativeInitialize(new File(root, "axiom-runtime.db").getAbsolutePath());
    result.put("status", value);
    if (value != 0) result.put("error", "AXIOM_UI_RUNTIME_INIT: native runtime initialization failed.");
    return result;
  }

  @LynxMethod
  public Map<String, Object> dispatch(Map<String, Object> envelope, Callback callback) {
    if (envelope == null || number(envelope.get("protocolVersion")) != FACADE_PROTOCOL_VERSION) {
      callback.invoke(status(2, "AXIOM_UI_RUNTIME_DISPATCH: invalid facade envelope."));
      return status(2, "AXIOM_UI_RUNTIME_DISPATCH: invalid facade envelope.");
    }
    // The complete verified-contract argument surface is deliberately JNI
    // owned.  This Java boundary accepts no filesystem paths or arbitrary
    // native symbols. It returns a one-shot acknowledgement as required by
    // Lynx Android's Callback contract.
    callback.invoke(status(2, "AXIOM_UI_ANDROID_RUNTIME_PENDING: Android contract dispatch requires the Phase 5E JNI event-channel conformance fixture."));
    return status(2, "AXIOM_UI_ANDROID_RUNTIME_PENDING: request was not sent.");
  }

  @LynxMethod public Map<String, Object> cancel(double requestId) {
    Map<String, Object> result = status(nativeCancel((long) requestId), null);
    result.put("requestId", (long) requestId);
    return result;
  }

  @LynxMethod public Map<String, Object> close() { return status(nativeClose(), null); }

  private static native int nativeAbiVersion();
  private static native int nativeInitialize(String databasePath);
  private static native int nativeCancel(long requestId);
  private static native int nativeClose();

  private static int number(Object value) { return value instanceof Number ? ((Number) value).intValue() : -1; }
  private static Map<String, Object> status(int value, String error) {
    Map<String, Object> result = new HashMap<>(); result.put("status", value);
    if (error != null) result.put("error", error); return result;
  }
}
