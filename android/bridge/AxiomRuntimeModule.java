package com.axiom.uihost;

import android.content.Context;
import com.lynx.jsbridge.LynxMethod;
import com.lynx.jsbridge.LynxModule;

/**
 * Narrow Android counterpart of the iOS Axiom bridge. Renderer code receives
 * only typed contract operations; Rust remains behind the stable C/JNI ABI.
 */
public final class AxiomRuntimeModule extends LynxModule {
  static {
    System.loadLibrary("axiom_runtime");
  }

  public AxiomRuntimeModule(Context context) { super(context); }

  @LynxMethod
  public int abiVersion() { return nativeAbiVersion(); }

  @LynxMethod
  public int initialize(String databasePath) { return nativeInitialize(databasePath); }

  @LynxMethod
  public int cancel(long requestId) { return nativeCancel(requestId); }

  private static native int nativeAbiVersion();
  private static native int nativeInitialize(String databasePath);
  private static native int nativeCancel(long requestId);
}
