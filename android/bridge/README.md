# Android bridge overlay

`AxiomRuntimeModule` is copied into the staged Android host and registered from
the host application's existing module adapter:

```java
LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
```

The overlay provides ABI probing, hash-locked contract loading, typed dispatch,
cancellation, and app-private initialization through an Axiom JNI wrapper. `AxiomHostActivity` owns the
separate fixed-name v2 bundle/revision/ack protocol. It loads bundles from
`files/axiom-ui-host` only after the CLI has copied them through `adb run-as`.

Lynx Android callbacks are single-use. Dispatch therefore uses its callback
only for the acknowledgement and exposes runtime responses through a sequence
of one-shot `poll` calls. The handwritten Lynx adapter turns that bounded poll
channel back into the same typed event protocol used on iOS. The APK is an Axiom **development host** (debuggable but
release-key-signed), never a production application distribution. Its JNI
library is Axiom-built Rust output plus the small Axiom-owned C++ wrapper, not
a vendor prebuilt binary.

Local dependency configuration stays portable and may use
`http://127.0.0.1:<port>`. Inside the Android Emulator the bridge translates a
loopback host to the emulator gateway at `10.0.2.2`. Physical development
devices keep the original URL and use the CLI-managed `adb reverse` tunnel.
