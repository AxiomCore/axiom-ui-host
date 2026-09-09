package com.axiom.uihost;

import android.app.Application;
import com.lynx.tasm.LynxEnv;

/** Boots only the renderer services needed by the Axiom-owned host. */
public final class AxiomHostApplication extends Application {
  @Override public void onCreate() {
    super.onCreate();
    LynxEnv.inst().init(this, null, null, null);
    LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
  }
}
