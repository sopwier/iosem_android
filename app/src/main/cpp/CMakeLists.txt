cmake_minimum_required(VERSION 3.22.1)

project(iosem_core CXX)

add_library(iosem_core SHARED native_core.cpp)

target_compile_features(iosem_core PRIVATE cxx_std_17)

find_library(log-lib log)
target_link_libraries(iosem_core ${log-lib})
