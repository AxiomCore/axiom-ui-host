cmake_minimum_required(VERSION 3.18.1)
project(axiom_runtime_jni)

add_library(axiom_runtime SHARED IMPORTED)
set_target_properties(axiom_runtime PROPERTIES
  # Keep CMake-imported prebuilts outside src/main/jniLibs. AGP packages an
  # IMPORTED shared library automatically; placing the same file in jniLibs
  # makes mergeNativeLibs see two copies of libaxiom_runtime.so.
  IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../nativeDeps/${ANDROID_ABI}/libaxiom_runtime.so"
  # Rust's cdylib currently has no DT_SONAME. Without this property CMake
  # records IMPORTED_LOCATION itself in libaxiom_runtime_jni.so's DT_NEEDED,
  # leaking the release machine's absolute path into the APK. Ask the Android
  # linker to resolve the packaged library by its basename instead.
  IMPORTED_NO_SONAME TRUE)

add_library(axiom_runtime_jni SHARED AxiomRuntimeJni.cpp)
target_include_directories(axiom_runtime_jni PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(axiom_runtime_jni axiom_runtime log)
