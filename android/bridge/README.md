# Android bridge overlay

`AxiomRuntimeModule` is copied into the staged Android host and registered from
the host application's existing module adapter:

```java
LynxEnv.inst().registerModule("AxiomRuntime", AxiomRuntimeModule.class);
```

The current overlay provides ABI probing, initialization and cancellation. The
typed request/response callback bridge must be completed before Android is
marked delivery-ready; the build scripts consequently package a host as a
development host, never as a production delivery claim. Its JNI library is an
Axiom-built Rust output and not a vendor prebuilt binary.
