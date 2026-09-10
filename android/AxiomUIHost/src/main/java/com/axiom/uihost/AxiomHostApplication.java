package com.axiom.uihost;

import android.app.Application;
import com.facebook.drawee.backends.pipeline.Fresco;
import com.lynx.service.image.LynxImageService;
import com.lynx.tasm.LynxEnv;
import com.lynx.tasm.service.LynxServiceCenter;

/** Boots only the renderer services needed by the Axiom-owned host. */
public final class AxiomHostApplication extends Application {
  @Override public void onCreate() {
    super.onCreate();

    // LynxEnv initializes only services that have already been registered.
    // Register the image implementation before init so every LynxView can
    // resolve image rendering and prefetch. Do not activate optional services
    // unless the host also packages all of their runtime dependencies.
    LynxServiceCenter.inst().registerService(LynxImageService.getInstance());
    LynxEnv.inst().init(this, null, null, null);

    // LynxImageService delegates decoding and caching to Fresco. Initialize it
    // before the first template can create an image or issue a prefetch.
    Fresco.initialize(getApplicationContext());
    LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
  }
}
