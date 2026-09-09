#include <jni.h>
#include "axiom.h"

namespace {
AxiomString string_from(JNIEnv* env, jstring value) {
  if (value == nullptr) return {nullptr, 0};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {nullptr, 0};
  const jsize length = env->GetStringUTFLength(value);
  // axiom_initialize consumes its string before it returns. The caller releases
  // the JNI chars immediately after that call.
  return {reinterpret_cast<const uint8_t*>(chars), static_cast<size_t>(length)};
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeAbiVersion(JNIEnv*, jclass) {
  return static_cast<jint>(axiom_abi_version());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeInitialize(JNIEnv* env, jclass, jstring path) {
  if (path == nullptr) return 2;
  AxiomString value = string_from(env, path);
  if (value.ptr == nullptr) return 2;
  const jint result = axiom_initialize(value);
  env->ReleaseStringUTFChars(path, reinterpret_cast<const char*>(value.ptr));
  return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeCancel(JNIEnv*, jclass, jlong request_id) {
  return axiom_cancel(static_cast<uint64_t>(request_id));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_axiom_uihost_AxiomRuntimeModule_nativeClose(JNIEnv*, jclass) {
  // Clearing first waits for any in-flight ABI callback before the Java module
  // can be destroyed. This matches ABI-v1 ownership semantics.
  axiom_clear_callback();
  return 0;
}
