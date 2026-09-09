cmake_minimum_required(VERSION 3.22.1)
project(axiom_runtime_jni)

add_library(axiom_runtime SHARED IMPORTED)
set_target_properties(axiom_runtime PROPERTIES
  IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libaxiom_runtime.so")

add_library(axiom_runtime_jni SHARED AxiomRuntimeJni.cpp)
target_include_directories(axiom_runtime_jni PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(axiom_runtime_jni axiom_runtime log)
