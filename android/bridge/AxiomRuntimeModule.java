package com.axiom.uihost;

import android.content.Context;
import android.util.Base64;
import com.lynx.react.bridge.Callback;
import com.lynx.jsbridge.LynxMethod;
import com.lynx.jsbridge.LynxModule;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Locked-contract bridge. Rust owns HTTP, validation, caching, and errors. */
public final class AxiomRuntimeModule extends LynxModule {
  private static final int PROTOCOL = 1;
  private static final int MODULE_VERSION = 1;
  private static final ConcurrentHashMap<String, Operation> ALLOWED = new ConcurrentHashMap<>();
  private static final ConcurrentLinkedQueue<Map<String, Object>> EVENTS = new ConcurrentLinkedQueue<>();
  private static final ScheduledExecutorService PUMP = Executors.newSingleThreadScheduledExecutor(r -> {
    Thread thread = new Thread(r, "axiom-runtime-response-pump");
    thread.setDaemon(true);
    return thread;
  });
  private static boolean initialized;
  private static boolean pumpStarted;
  private static String loadedFingerprint;

  static { System.loadLibrary("axiom_runtime_jni"); }
  public AxiomRuntimeModule(Context context) { super(context); }

  @LynxMethod public Map<String, Object> runtimeInfo() {
    Map<String, Object> result = new HashMap<>();
    result.put("moduleVersion", MODULE_VERSION);
    result.put("runtimeAbiVersion", nativeAbiVersion());
    result.put("target", "android");
    result.put("capabilities", new String[] {"query", "mutation", "cancel"});
    return result;
  }

  @LynxMethod public synchronized Map<String, Object> initialize(Map<String, Object> config) {
    if (config == null || integer(config.get("protocolVersion")) != PROTOCOL ||
        !(config.get("contracts") instanceof List) || ((List<?>) config.get("contracts")).isEmpty()) {
      return status(2, "AXIOM_UI_RUNTIME_CONFIG: a non-empty protocol-1 contract configuration is required.");
    }
    if (!initialized) {
      File root = new File(mContext.getFilesDir(), "axiom-ui-host");
      if (!root.exists() && !root.mkdirs()) return status(2, "AXIOM_UI_RUNTIME_INIT: cannot create runtime storage.");
      int value = nativeInitialize(new File(root, "axiom-runtime.db").getAbsolutePath());
      if (value != 0) return status(value, "AXIOM_UI_RUNTIME_INIT: native runtime initialization failed.");
      nativeRegisterCallback();
      initialized = true;
    }
    List<?> contracts = (List<?>) config.get("contracts");
    String fingerprint = String.valueOf(contracts);
    if (loadedFingerprint != null && !loadedFingerprint.equals(fingerprint)) {
      return status(2, "AXIOM_UI_RUNTIME_RESTART_REQUIRED: contract inputs changed; restart the host.");
    }
    boolean load = loadedFingerprint == null;
    boolean allVerified = true;
    HashMap<String, Operation> approved = new HashMap<>();
    for (Object candidate : contracts) {
      if (!(candidate instanceof Map)) return status(2, "AXIOM_UI_RUNTIME_CONFIG: invalid contract entry.");
      Map<?, ?> contract = (Map<?, ?>) candidate;
      String namespace = required(contract.get("namespace"));
      String baseUrl = required(contract.get("baseUrl"));
      String encoded = required(contract.get("artifactBase64"));
      String signature = optional(contract.get("signature"));
      String publicKey = optional(contract.get("publicKey"));
      String expectedHash = required(contract.get("expectedSha256"));
      boolean verified = Boolean.TRUE.equals(contract.get("verified"));
      if (namespace == null || baseUrl == null || encoded == null || signature == null || publicKey == null ||
          expectedHash == null || !(contract.get("operations") instanceof List) ||
          (verified && (signature.isEmpty() || publicKey.isEmpty()))) {
        return status(2, "AXIOM_UI_RUNTIME_CONFIG: contract has incomplete locked inputs.");
      }
      byte[] artifact;
      try { artifact = Base64.decode(encoded, Base64.DEFAULT); }
      catch (IllegalArgumentException error) { return status(2, "AXIOM_UI_RUNTIME_CONFIG: invalid artifact encoding."); }
      if (artifact.length == 0) return status(2, "AXIOM_UI_RUNTIME_CONFIG: empty contract artifact.");
      if (load) {
        int value = nativeLoadContract(namespace, baseUrl, artifact, signature, publicKey, expectedHash);
        if (value != 0 && value != -1) return status(value, "AXIOM_UI_RUNTIME_VERIFY: locked contract loading failed.");
        if ((value == 0) != verified) return status(2, "AXIOM_UI_RUNTIME_VERIFY: verification state differs from its lock.");
      }
      if (!verified) allVerified = false;
      for (Object item : (List<?>) contract.get("operations")) {
        if (!(item instanceof Map)) return status(2, "AXIOM_UI_RUNTIME_CONFIG: invalid operation entry.");
        Map<?, ?> operation = (Map<?, ?>) item;
        long endpointId = longValue(operation.get("endpointId"));
        String method = required(operation.get("method"));
        String path = required(operation.get("path"));
        String kind = required(operation.get("kind"));
        if (endpointId <= 0 || method == null || path == null ||
            !("query".equals(kind) || "mutation".equals(kind) || "stream".equals(kind))) {
          return status(2, "AXIOM_UI_RUNTIME_CONFIG: invalid operation capability.");
        }
        if (approved.put(key(namespace, endpointId), new Operation(method, path, kind)) != null) {
          return status(2, "AXIOM_UI_RUNTIME_CONFIG: duplicate operation capability.");
        }
      }
    }
    ALLOWED.clear(); ALLOWED.putAll(approved); loadedFingerprint = fingerprint;
    if (!pumpStarted) { pumpStarted = true; PUMP.scheduleWithFixedDelay(AxiomRuntimeModule::nativeProcessResponses, 0, 5, TimeUnit.MILLISECONDS); }
    Map<String, Object> result = status(0, null);
    result.put("verified", allVerified); result.put("loadedContracts", contracts.size());
    return result;
  }

  @LynxMethod public Map<String, Object> dispatch(Map<String, Object> envelope, Callback callback) {
    Map<String, Object> result = dispatchOnce(envelope);
    callback.invoke(result); // acknowledgement only: Lynx Android callbacks are single-use
    return result;
  }

  private Map<String, Object> dispatchOnce(Map<String, Object> envelope) {
    if (envelope == null || integer(envelope.get("protocolVersion")) != PROTOCOL || !(envelope.get("request") instanceof Map)) {
      return ack(2, "AXIOM_UI_RUNTIME_DISPATCH: invalid facade envelope.");
    }
    long requestId = longValue(envelope.get("requestId"));
    Map<?, ?> request = (Map<?, ?>) envelope.get("request");
    long endpointId = longValue(request.get("endpointId"));
    String namespace = required(request.get("namespace"));
    String method = required(request.get("method"));
    String path = required(request.get("path"));
    String kind = required(request.get("kind"));
    Operation allowed = namespace == null ? null : ALLOWED.get(key(namespace, endpointId));
    if (requestId <= 0 || allowed == null || !allowed.matches(method, path, kind) || !kind.equals(required(envelope.get("kind")))) {
      return ack(2, "AXIOM_UI_OPERATION_DENIED: request is absent from the contract capability set.");
    }
    byte[] payload;
    try { payload = Base64.decode(text(request.get("payloadBase64"), ""), Base64.DEFAULT); }
    catch (IllegalArgumentException error) { return ack(2, "AXIOM_UI_RUNTIME_DISPATCH: invalid payload encoding."); }
    int value = nativeCall(requestId, namespace, endpointId, method, path,
        text(request.get("traceparent"), ""), text(request.get("headersJson"), "{}"), payload);
    return ack(value, value == 0 ? null : "Axiom runtime rejected the request.");
  }

  /** Drains one event because the pinned Lynx Callback implementation is one-shot. */
  @LynxMethod public void poll(Callback callback) {
    Map<String, Object> event = EVENTS.poll();
    callback.invoke(event == null ? status(0, null) : event);
  }

  @LynxMethod public Map<String, Object> cancel(double requestId) {
    Map<String, Object> result = status(nativeCancel((long) requestId), null);
    result.put("requestId", (long) requestId); return result;
  }
  @LynxMethod public Map<String, Object> close() { return status(0, null); }

  private static void onNativeResponse(long requestId, int eventType, int eventStatus, byte[] data, byte[] error) {
    Map<String, Object> event = new HashMap<>();
    event.put("protocolVersion", PROTOCOL); event.put("requestId", requestId);
    event.put("eventType", eventType); event.put("status", eventStatus);
    event.put("data", new String(data, StandardCharsets.UTF_8));
    event.put("error", new String(error, StandardCharsets.UTF_8));
    EVENTS.add(event);
  }

  private static native int nativeAbiVersion();
  private static native int nativeInitialize(String databasePath);
  private static native int nativeLoadContract(String namespace, String baseUrl, byte[] artifact, String signature, String publicKey, String expectedSha256);
  private static native void nativeRegisterCallback();
  private static native int nativeCall(long requestId, String namespace, long endpointId, String method, String path, String traceparent, String headersJson, byte[] payload);
  private static native void nativeProcessResponses();
  private static native int nativeCancel(long requestId);

  private static String key(String namespace, long endpointId) { return namespace + ":" + endpointId; }
  private static int integer(Object value) { return value instanceof Number ? ((Number) value).intValue() : -1; }
  private static long longValue(Object value) { return value instanceof Number ? ((Number) value).longValue() : -1; }
  private static String required(Object value) { return value instanceof String && !((String) value).isEmpty() ? (String) value : null; }
  private static String optional(Object value) { return value instanceof String ? (String) value : null; }
  private static String text(Object value, String fallback) { return value instanceof String ? (String) value : fallback; }
  private static Map<String, Object> status(int value, String error) {
    Map<String, Object> result = new HashMap<>(); result.put("status", value);
    if (error != null) result.put("error", error); return result;
  }
  private static Map<String, Object> ack(int value, String error) {
    Map<String, Object> result = status(value, error); result.put("accepted", true); return result;
  }
  private static final class Operation {
    final String method, path, kind;
    Operation(String method, String path, String kind) { this.method = method; this.path = path; this.kind = kind; }
    boolean matches(String method, String path, String kind) { return this.method.equals(method) && this.path.equals(path) && this.kind.equals(kind); }
  }
}
