# Android bridge overlay

`AxiomRuntimeModule` is copied into the staged Android host and registered from
the host application's existing module adapter:

```java
LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
```

The overlay provides ABI probing, app-private initialization, cancellation, and
close ownership through an Axiom JNI wrapper. `AxiomHostActivity` owns the
separate fixed-name v2 bundle/revision/ack protocol. It loads bundles from
`files/axiom-ui-host` only after the CLI has copied them through `adb run-as`.

Lynx Android callbacks are single-use. Therefore the bridge never pretends to
offer iOS-style multi-event callback streaming: it rejects contract dispatch
with an explicit `AXIOM_UI_ANDROID_RUNTIME_PENDING` diagnostic until the
event-channel adapter and its conformance fixture land. The APK is an Axiom **development host** (debuggable but
release-key-signed), never a production application distribution. Its JNI
library is Axiom-built Rust output plus the small Axiom-owned C++ wrapper, not
a vendor prebuilt binary.
