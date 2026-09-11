#include <jni.h>
#include <mutex>
#include "axiom.h"

namespace {
JavaVM* g_vm = nullptr;
jclass g_module_class = nullptr;
std::mutex g_bridge_mutex;

class UtfString {
 public:
  UtfString(JNIEnv* env, jstring value) : env_(env), value_(value) {
    if (value_) chars_ = env_->GetStringUTFChars(value_, nullptr);
  }
  ~UtfString() { if (chars_) env_->ReleaseStringUTFChars(value_, chars_); }
  AxiomString view() const {
    return chars_ ? AxiomString{reinterpret_cast<const uint8_t*>(chars_),
                               static_cast<size_t>(env_->GetStringUTFLength(value_))}
                  : AxiomString{nullptr, 0};
  }
  bool valid() const { return chars_ != nullptr; }
 private:
  JNIEnv* env_; jstring value_; const char* chars_ = nullptr;
};

jbyteArray byte_array(JNIEnv* env, const AxiomBuffer& value) {
  jbyteArray result = env->NewByteArray(static_cast<jsize>(value.len));
  if (result && value.ptr && value.len) {
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(value.len),
                            reinterpret_cast<const jbyte*>(value.ptr));
  }
  return result;
}

void runtime_response(const AxiomResponseBuffer* response) {
  if (!response || !g_vm) return;
  JNIEnv* env = nullptr;
  bool detach = false;
  jint state = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (state == JNI_EDETACHED) {
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
    detach = true;
  } else if (state != JNI_OK) {
    return;
  }
  jclass module_class;
  {
    std::lock_guard<std::mutex> lock(g_bridge_mutex);
    module_class = g_module_class;
  }
  if (module_class) {
    jmethodID method = env->GetStaticMethodID(module_class, "onNativeResponse", "(JII[B[B)V");
    if (method) {
      jbyteArray data = byte_array(env, response->data);
      jbyteArray error = byte_array(env, response->error_message);
      env->CallStaticVoidMethod(module_class, method, static_cast<jlong>(response->request_id),
                                static_cast<jint>(response->event_type),
                                static_cast<jint>(response->error_code), data, error);
      if (data) env->DeleteLocalRef(data);
      if (error) env->DeleteLocalRef(error);
    }
  }
  axiom_free_response_buffer(const_cast<AxiomResponseBuffer*>(response));
  if (detach) g_vm->DetachCurrentThread();
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeAbiVersion(JNIEnv*, jclass) {
  return static_cast<jint>(axiom_abi_version());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeInitialize(JNIEnv* env, jclass, jstring path) {
  UtfString value(env, path);
  return value.valid() ? axiom_initialize(value.view()) : 2;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeLoadContract(
    JNIEnv* env, jclass, jstring namespace_value, jstring base_url, jbyteArray artifact,
    jstring signature, jstring public_key, jstring expected_hash) {
  if (!artifact) return 2;
  UtfString ns(env, namespace_value), url(env, base_url), sig(env, signature), key(env, public_key), hash(env, expected_hash);
  if (!ns.valid() || !url.valid() || !sig.valid() || !key.valid() || !hash.valid()) return 2;
  jbyte* bytes = env->GetByteArrayElements(artifact, nullptr);
  if (!bytes) return 2;
  AxiomBuffer buffer{reinterpret_cast<uint8_t*>(bytes), static_cast<size_t>(env->GetArrayLength(artifact))};
  jint result = axiom_load_contract_locked(ns.view(), url.view(), buffer, sig.view(), key.view(), hash.view());
  env->ReleaseByteArrayElements(artifact, bytes, JNI_ABORT);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeRegisterCallback(JNIEnv* env, jclass clazz) {
  std::lock_guard<std::mutex> lock(g_bridge_mutex);
  env->GetJavaVM(&g_vm);
  if (g_module_class) env->DeleteGlobalRef(g_module_class);
  g_module_class = reinterpret_cast<jclass>(env->NewGlobalRef(clazz));
  axiom_register_callback(runtime_response);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeCall(
    JNIEnv* env, jclass, jlong request_id, jstring namespace_value, jlong endpoint_id,
    jstring method, jstring path, jstring traceparent, jstring headers, jbyteArray payload) {
  UtfString ns(env, namespace_value), method_value(env, method), path_value(env, path),
      trace_value(env, traceparent), header_value(env, headers);
  if (!ns.valid() || !method_value.valid() || !path_value.valid() || !trace_value.valid() || !header_value.valid()) return 2;
  jbyte* bytes = payload ? env->GetByteArrayElements(payload, nullptr) : nullptr;
  AxiomBuffer buffer{reinterpret_cast<uint8_t*>(bytes),
                     payload ? static_cast<size_t>(env->GetArrayLength(payload)) : 0};
  jint result = axiom_call(static_cast<uint64_t>(request_id), ns.view(), static_cast<uint32_t>(endpoint_id),
                           method_value.view(), path_value.view(), trace_value.view(), header_value.view(), buffer);
  if (bytes) env->ReleaseByteArrayElements(payload, bytes, JNI_ABORT);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeProcessResponses(JNIEnv*, jclass) {
  axiom_process_responses();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeCancel(JNIEnv*, jclass, jlong request_id) {
  return axiom_cancel(static_cast<uint64_t>(request_id));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeClose(JNIEnv*, jclass) {
  axiom_reset_session();
  axiom_clear_callback();
  return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeResetSession(JNIEnv*, jclass) {
  axiom_reset_session();
}
