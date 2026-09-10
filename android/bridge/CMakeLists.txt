cmake_minimum_required(VERSION 3.18.1)
project(axiom_runtime_jni)

add_library(axiom_runtime STATIC IMPORTED)
set_target_properties(axiom_runtime PROPERTIES
  # Embed the Rust runtime into the JNI bridge. Older Android Gradle Plugin
  # versions do not reliably package a transitive IMPORTED shared library,
  # which produced an APK whose JNI bridge depended on a missing .so.
  IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../nativeDeps/${ANDROID_ABI}/libaxiom_runtime.a")

add_library(axiom_runtime_jni SHARED AxiomRuntimeJni.cpp)
target_include_directories(axiom_runtime_jni PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(axiom_runtime_jni axiom_runtime log android dl m)
