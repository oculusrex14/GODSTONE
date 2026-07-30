cmake_minimum_required(VERSION 3.22.1)
project("godstone_llm")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# llama.cpp is vendored as a git submodule at third_party/llama.cpp so the build
# is fully reproducible offline. Nothing is fetched at build time.
set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/llama.cpp)

set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)

add_subdirectory(${LLAMA_DIR} ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(godstone_llm SHARED
    godstone_llm_jni.cpp
)

target_include_directories(godstone_llm PRIVATE
    ${LLAMA_DIR}
    ${LLAMA_DIR}/common
    ${LLAMA_DIR}/ggml/include
)

target_link_libraries(godstone_llm
    llama
    common
    android
    log
)

target_compile_options(godstone_llm PRIVATE
    -O3
    -ffast-math
    -funroll-loops
)
