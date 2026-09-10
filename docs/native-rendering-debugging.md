# Debugging Axiom native UI rendering

Use this guide when `axiom run` reports that native delivery was acknowledged,
but a component is missing or an interaction appears inert.

## Follow the boundary in order

The runtime path is:

```text
.acore source
  -> validated Axiom UI IR
  -> virtual ReactLynx TSX and CSS
  -> compiled .lynx.bundle
  -> CLI delivery record
  -> native host LynxView
  -> registered native Behavior/UI class
  -> background event callback
  -> ReactLynx state update
```

An acknowledgement proves that the host received and submitted the bundle to
Lynx. It does not prove that every element has a native implementation or that
an event handler changed state.

While `axiom run` remains open, the host also publishes a bounded queue of
asynchronous Lynx diagnostics as `axiom-ui-host-diagnostics/v1`. The CLI
reports renderer, JavaScript, native component, resource, and layout errors
associated with the active graph. Use `DEBUG=true axiom run ...` (or
`AXIOM_UI_DEBUG=true`) to show delivery sequence, full graph revision, fallback
reasons, and host suggestions. Normal mode intentionally keeps successful
compile/delivery messages short.

Only diagnostics emitted by Lynx can cross this channel. A platform may not
classify every visually undesirable layout (for example intentional clipping)
as an error, so device acceptance tests remain necessary for presentation.

## 1. Inspect compiler output

The `UI reload` line prints a graph revision. Its opaque generated project is:

```text
~/Library/Caches/axiom/ui/builds/<graph-revision>/<target>-<process>/virtual/
```

Inspect the page TSX and `axiom-ui.css`. For an Axiom `Input`, confirm that the
page contains a native `<input>`, `bindinput`, the expected state setter, and
its structural class. For a button, confirm `bindtap` points to the expected
action. Presentation properties must appear only when authored in Acore; the
base stylesheet must not invent padding, gaps, colors, radius, or control
height. Event callbacks passed through a hook or component boundary must be
marked with Lynx's `background only` directive.

If those are wrong, trace the primitive lowerer and action lowerer in
`axiom-ui/src/lib.rs`. If they are right, continue into the host rather than
changing the `.acore` source.

## 2. Check the Android native registry

Clear old logs, reproduce once, and inspect the first runtime exception:

```sh
adb logcat -c
axiom run main.acore --target android
adb logcat -d | rg 'AxiomUIHost|Lynx|BehaviorController|RuntimeException'
```

This signature means the bundle requested a valid native element that the host
did not install:

```text
No BehaviorController defined for class input
```

`input` is supplied by `:LynxXElement:Input`; it is not built into
`:LynxAndroid`. The Axiom host links that narrow module and registers a
`Behavior("input")` with both `LynxUIInput` and `LynxUIInputShadowNode` in
`AxiomHostActivity`. The UI class creates the Android view; the shadow node
measures it. Both are required.

This diagnostic on every page, including pages with no authored image, means
the image service was linked but not registered before `LynxEnv.init()`:

```text
UI error LYNX_32102: An exception occurred when try to get image prefetch helper.
```

The resource module is installed for every Lynx page and resolves
`ILynxImageService` during construction. The Android application must register
`LynxImageService.getInstance()` in `LynxServiceCenter` before initializing
`LynxEnv`; it must also package and initialize Fresco because the pinned image
service declares that backend as `compileOnly`. Do not hide `LYNX_32102` in the
CLI: a missing service would also break real `<image>` rendering and prefetch.

Register only the services whose complete runtime dependency graph is packaged
by the product host. In particular, `LynxHttpService` constructs an
`okhttp3.OkHttpClient`; activating that service without adding the OkHttp
runtime crashes `AxiomHostApplication.onCreate()` before the host can write an
acknowledgement. The CLI then reports `AXIOM_UI_HOST_ACK_TIMEOUT`, which is a
secondary symptom. Confirm startup failures with:

```sh
adb logcat -d -b crash | rg 'dev.axiomcore.uihost|FATAL EXCEPTION|Caused by'
```

## 3. Check the iOS native registry

Use the Simulator/Xcode console and search for `Lynx`, `input`, and Axiom host
messages. The iOS equivalent is the `XElement/Input` pod plus explicit
registration of both `LynxUIInput` and `LynxUIInputShadowNode` on the
`LynxConfig` in `AxiomHostViewController`.

If text and built-in views render but only `<input>` is absent, compare the
Podfile and those registrations before investigating layout. A CSS fix cannot
instantiate a native component that was never linked.

## 4. Make interaction tests observable

Typing into the Phase 5 local-interaction example must update `draft`; tapping
Submit must copy that value to `submitted` and clear the field. Resetting an
already-empty initial page produces the same visible state and therefore is
not, by itself, evidence that tap delivery failed.

When tracing callbacks, inspect the generated action first, then the native
event log. Normal `bindtap` and `bindinput` handlers run against ReactLynx's
background runtime. A callback passed through `useCallback` is explicitly
marked `background only` by the Axiom lowerer so the compiler does not retain
the wrong dual-runtime copy.

## Regression gates

- `cargo test --manifest-path axiom-ui/Cargo.toml --lib` checks generated event
  bindings and directives.
- `axiom-ui-host/tests/validate-host.sh` checks that both host targets link and
  register native Input support.
- Device validation must still type a non-empty value, submit it, and reset it
  on both iOS Simulator and Android Emulator.
- Run iOS and Android watchers together and edit once; their Rspeedy workspaces
  must remain isolated under `builds/<graph>/<target>-<process>`.
