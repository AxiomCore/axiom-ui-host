package com.axiom.uihost;

import android.app.Application;
import com.facebook.drawee.backends.pipeline.Fresco;
import com.lynx.service.http.LynxHttpService;
import com.lynx.service.image.LynxImageService;
import com.lynx.service.log.LynxLogService;
import com.lynx.tasm.LynxEnv;
import com.lynx.tasm.service.LynxServiceCenter;

/** Boots only the renderer services needed by the Axiom-owned host. */
public final class AxiomHostApplication extends Application {
  @Override public void onCreate() {
    super.onCreate();

    // LynxEnv initializes only services that have already been registered.
    // Register the service implementations linked by this host before init so
    // every LynxView can resolve image prefetch, fetch, and platform logging.
    LynxServiceCenter.inst().registerService(LynxLogService.INSTANCE);
    LynxServiceCenter.inst().registerService(LynxImageService.getInstance());
    LynxServiceCenter.inst().registerService(LynxHttpService.INSTANCE);
    LynxEnv.inst().init(this, null, null, null);

    // LynxImageService delegates decoding and caching to Fresco. Initialize it
    // before the first template can create an image or issue a prefetch.
    Fresco.initialize(getApplicationContext());
    LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
  }
}
