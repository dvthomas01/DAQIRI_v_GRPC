cmake_minimum_required(VERSION 3.20)
# Pipeline B — gRPC Direct + GPU FFT benchmark
# Builds entirely from pre-built gRPC/grpc-direct artifacts in
# ~/grpc_benchmarking — no FetchContent, no Go compiler required.
project(grpc_pipeline_fft LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CUDA_ARCHITECTURES 90)

# =============================================================================
# All pre-built artifact paths
# =============================================================================
set(GRPC_BENCH  "$ENV{HOME}/grpc_benchmarking/cpp/build"
    CACHE PATH "grpc_benchmarking build dir (pre-built gRPC artifacts)")
set(GRPC_BUILD  "${GRPC_BENCH}/_deps/grpc-build")
set(GRPC_SRC    "${GRPC_BENCH}/_deps/grpc-src")
set(GD_BUILD    "${GRPC_BENCH}/grpc-direct-build"
    CACHE PATH "Pre-built grpc-direct artifacts")
set(GD_SRC      "$ENV{HOME}/grpc-direct"
    CACHE PATH "grpc-direct SDK source root")
set(DAQIRI_GPU_ROOT "$ENV{HOME}/daqiri_gpu"
    CACHE PATH "Root of the daqiri_gpu project")

foreach(_required "${GRPC_BUILD}/libgrpc++.a" "${GD_BUILD}/libgrpc_direct_cpp.a")
    if(NOT EXISTS "${_required}")
        message(FATAL_ERROR "Required pre-built lib missing: ${_required}\n"
            "Run: cd ~/grpc_benchmarking/cpp && cmake --build build")
    endif()
endforeach()

# =============================================================================
# Locate pre-built codegen tools (absolute paths — no cmake TARGET needed)
# =============================================================================
set(PROTOC_EXE       "${GRPC_BUILD}/third_party/protobuf/protoc")
set(GRPC_CPP_PLUGIN  "${GRPC_BUILD}/grpc_cpp_plugin")
set(GD_PLUGIN        "${GD_BUILD}/protoc-gen-grpc-direct")

foreach(_tool ${PROTOC_EXE} ${GRPC_CPP_PLUGIN} ${GD_PLUGIN})
    if(NOT EXISTS "${_tool}")
        message(FATAL_ERROR "Required tool missing: ${_tool}")
    endif()
endforeach()

message(STATUS "protoc          : ${PROTOC_EXE}")
message(STATUS "grpc_cpp_plugin : ${GRPC_CPP_PLUGIN}")
message(STATUS "grpc-direct plug: ${GD_PLUGIN}")

# =============================================================================
# Collect pre-built static libraries
# grpc-build top level  : libgrpc++.a libgrpc.a libgpr.a libaddress_sorting.a
#                         libupb*.a libssl*.a (bundled) etc.
# protobuf              : libprotobuf.a
# abseil-cpp (90 libs)  : globbed recursively
# cares / re2           : globbed recursively inside grpc-build
# =============================================================================
file(GLOB   GRPC_CORE_LIBS  "${GRPC_BUILD}/lib*.a")
file(GLOB   PROTO_LIBS      "${GRPC_BUILD}/third_party/protobuf/lib*.a")
file(GLOB_RECURSE PROTO_THIRD_LIBS "${GRPC_BUILD}/third_party/protobuf/third_party/*.a")
file(GLOB_RECURSE ABSL_LIBS "${GRPC_BUILD}/third_party/abseil-cpp/*.a")
file(GLOB_RECURSE CARES_LIBS "${GRPC_BUILD}/third_party/cares/*.a")
file(GLOB_RECURSE RE2_LIBS   "${GRPC_BUILD}/third_party/re2/*.a")
# gRPC is built against BoringSSL, NOT system OpenSSL — must use these
set(BORINGSSL_LIBS
    "${GRPC_BUILD}/third_party/boringssl-with-bazel/libssl.a"
    "${GRPC_BUILD}/third_party/boringssl-with-bazel/libcrypto.a"
)

# Interface library that wraps all pre-built gRPC/protobuf/absl with correct
# link group so circular deps between absl/grpc/protobuf resolve.
add_library(grpc_stack INTERFACE)
target_link_libraries(grpc_stack INTERFACE
    -Wl,--start-group
        ${GRPC_CORE_LIBS}
        ${PROTO_LIBS}
        ${PROTO_THIRD_LIBS}
        ${ABSL_LIBS}
        ${CARES_LIBS}
        ${RE2_LIBS}
        ${BORINGSSL_LIBS}
    -Wl,--end-group
    z m resolv pthread dl
)
target_include_directories(grpc_stack INTERFACE
    "${GRPC_SRC}/include"
    "${GRPC_SRC}/third_party/protobuf/src"
    "${GRPC_SRC}/third_party/abseil-cpp"
)

# =============================================================================
# grpc-direct — import pre-built static lib + Rust shared lib
# =============================================================================
set(GD_RPATH "${GD_BUILD}/cargo-target/release")

add_library(grpc_direct_cpp STATIC IMPORTED GLOBAL)
set_target_properties(grpc_direct_cpp PROPERTIES
    IMPORTED_LOCATION "${GD_BUILD}/libgrpc_direct_cpp.a"
    INTERFACE_INCLUDE_DIRECTORIES "${GD_SRC}/include;${GD_BUILD}"
)

# =============================================================================
# CUDA
# =============================================================================
find_package(CUDAToolkit REQUIRED)

# =============================================================================
# Common / FFT helpers from the main daqiri_gpu project
# =============================================================================
add_subdirectory("${DAQIRI_GPU_ROOT}/common" common)
add_subdirectory("${DAQIRI_GPU_ROOT}/fft"    fft)

# =============================================================================
# Proto codegen — uses absolute paths to pre-built tools (no cmake targets)
# =============================================================================
set(PROTO_FILE "${CMAKE_CURRENT_SOURCE_DIR}/pipeline_fft.proto")
set(PROTO_OUT  "${CMAKE_CURRENT_BINARY_DIR}")
set(GD_PROTO_DIR "${GD_SRC}/proto")

add_custom_command(
    OUTPUT
        "${PROTO_OUT}/pipeline_fft.pb.cc"
        "${PROTO_OUT}/pipeline_fft.pb.h"
        "${PROTO_OUT}/pipeline_fft.grpc.pb.cc"
        "${PROTO_OUT}/pipeline_fft.grpc.pb.h"
    COMMAND "${PROTOC_EXE}"
        --grpc_out "${PROTO_OUT}"
        --cpp_out  "${PROTO_OUT}"
        -I "${CMAKE_CURRENT_SOURCE_DIR}"
        -I "${GD_PROTO_DIR}"
        --plugin=protoc-gen-grpc="${GRPC_CPP_PLUGIN}"
        "${PROTO_FILE}"
    DEPENDS "${PROTO_FILE}"
    COMMENT "protoc: generating pipeline_fft stubs"
)

add_custom_command(
    OUTPUT "${PROTO_OUT}/pipeline_fft.grpc_direct.pb.h"
    COMMAND "${PROTOC_EXE}"
        --grpc-direct_out "${PROTO_OUT}"
        --plugin=protoc-gen-grpc-direct="${GD_PLUGIN}"
        -I "${CMAKE_CURRENT_SOURCE_DIR}"
        -I "${GD_PROTO_DIR}"
        "${PROTO_FILE}"
    # The protoc-gen-grpc-direct plugin has a naming inconsistency: the move
    # constructor initialises _actual but the private member is declared as
    # _response.  Patch the generated header in-place.
    COMMAND sed -i "s/_actual/_response/g"
            "${PROTO_OUT}/pipeline_fft.grpc_direct.pb.h"
    DEPENDS "${PROTO_FILE}"
    COMMENT "protoc-gen-grpc-direct: generating pipeline_fft companion header"
)

add_custom_target(pipeline_proto_gen DEPENDS
    "${PROTO_OUT}/pipeline_fft.pb.cc"
    "${PROTO_OUT}/pipeline_fft.pb.h"
    "${PROTO_OUT}/pipeline_fft.grpc.pb.cc"
    "${PROTO_OUT}/pipeline_fft.grpc.pb.h"
    "${PROTO_OUT}/pipeline_fft.grpc_direct.pb.h"
)

# pipeline_fft_std.proto — no grpc_direct.proto import, zero Rust-library deps
set(PROTO_STD_FILE "${CMAKE_CURRENT_SOURCE_DIR}/pipeline_fft_std.proto")
add_custom_command(
    OUTPUT
        "${PROTO_OUT}/pipeline_fft_std.pb.cc"
        "${PROTO_OUT}/pipeline_fft_std.pb.h"
        "${PROTO_OUT}/pipeline_fft_std.grpc.pb.cc"
        "${PROTO_OUT}/pipeline_fft_std.grpc.pb.h"
    COMMAND "${PROTOC_EXE}"
        --grpc_out "${PROTO_OUT}"
        --cpp_out  "${PROTO_OUT}"
        -I "${CMAKE_CURRENT_SOURCE_DIR}"
        --plugin=protoc-gen-grpc="${GRPC_CPP_PLUGIN}"
        "${PROTO_STD_FILE}"
    DEPENDS "${PROTO_STD_FILE}"
    COMMENT "protoc: generating pipeline_fft_std stubs (standard gRPC)"
)
add_custom_target(pipeline_proto_std_gen DEPENDS
    "${PROTO_OUT}/pipeline_fft_std.pb.cc"
    "${PROTO_OUT}/pipeline_fft_std.pb.h"
    "${PROTO_OUT}/pipeline_fft_std.grpc.pb.cc"
    "${PROTO_OUT}/pipeline_fft_std.grpc.pb.h"
)

# =============================================================================
# Shared include dirs
# =============================================================================
set(PIPELINE_INCS
    "${PROTO_OUT}"
    "${GD_BUILD}"           # grpc_direct.pb.h, grpc_direct_service*.pb.h
    "${GD_SRC}/include"     # grpc-direct SDK headers
    "${DAQIRI_GPU_ROOT}/common"
    "${DAQIRI_GPU_ROOT}/fft"
)

# =============================================================================
# bench_grpc_server
# =============================================================================
add_executable(bench_grpc_server
    bench_grpc_server.cc
    "${PROTO_OUT}/pipeline_fft.pb.cc"
    "${PROTO_OUT}/pipeline_fft.grpc.pb.cc"
)
add_dependencies(bench_grpc_server pipeline_proto_gen)
target_include_directories(bench_grpc_server PRIVATE ${PIPELINE_INCS})
# NOTE: libgrpc_direct_cpp.a is linked with --whole-archive so the zero-copy
# parse-table patcher (grpc_direct_wkt_zc_parse.cc) is retained.  That object
# has no externally-referenced symbols — it installs its TcParser patch via a
# static initializer — so a normal archive link drops it and ParseGDZCArrays
# silently falls back to a copy (samples._zcptr_ stays null).  Whole-archiving
# forces the initializer in, enabling true zero-copy (--zc-parse / Level 2).
target_link_libraries(bench_grpc_server PRIVATE
    -Wl,--whole-archive
    "${GD_BUILD}/libgrpc_direct_cpp.a"
    -Wl,--no-whole-archive
    grpc_stack
    signal_gen
    csv_logger
    cufft_executor
    CUDA::cudart
    CUDA::cufft
    -L"${GD_RPATH}" -lgrpc_direct
    nvidia-ml
)
set_target_properties(bench_grpc_server PROPERTIES
    BUILD_RPATH   "${GD_RPATH}"
    INSTALL_RPATH "${GD_RPATH}"
)

# =============================================================================
# bench_grpc_server_std — standard gRPC only (no grpc-direct library loaded)
# The Rust libgrpc_direct.so registers a global transport filter that intercepts
# all connections; this binary simply never links it, so the filter is absent.
# Uses pipeline_fft_std.proto which has no import "grpc_direct.proto" at all.
# =============================================================================
add_executable(bench_grpc_server_std
    bench_grpc_server.cc
    "${PROTO_OUT}/pipeline_fft_std.pb.cc"
    "${PROTO_OUT}/pipeline_fft_std.grpc.pb.cc"
)
add_dependencies(bench_grpc_server_std pipeline_proto_std_gen)
target_include_directories(bench_grpc_server_std PRIVATE
    "${PROTO_OUT}"
    "${DAQIRI_GPU_ROOT}/common"
    "${DAQIRI_GPU_ROOT}/fft"
)
target_compile_definitions(bench_grpc_server_std PRIVATE STANDARD_GRPC_ONLY)
target_link_libraries(bench_grpc_server_std PRIVATE
    grpc_stack
    signal_gen
    csv_logger
    cufft_executor
    CUDA::cudart
    CUDA::cufft
    nvidia-ml
)
# No grpc_direct_cpp, no -lgrpc_direct, no RPATH to cargo dir

# =============================================================================
# bench_grpc_client
# =============================================================================
add_executable(bench_grpc_client
    bench_grpc_client.cc
    "${PROTO_OUT}/pipeline_fft.pb.cc"
    "${PROTO_OUT}/pipeline_fft.grpc.pb.cc"
)
add_dependencies(bench_grpc_client pipeline_proto_gen)
target_include_directories(bench_grpc_client PRIVATE ${PIPELINE_INCS})
target_link_libraries(bench_grpc_client PRIVATE
    grpc_direct_cpp
    grpc_stack
    signal_gen
    -L"${GD_RPATH}" -lgrpc_direct
)
set_target_properties(bench_grpc_client PROPERTIES
    BUILD_RPATH   "${GD_RPATH}"
    INSTALL_RPATH "${GD_RPATH}"
)

# =============================================================================
# bench_grpc_client_std — standard gRPC only, no libgrpc_direct.so
# =============================================================================
add_executable(bench_grpc_client_std
    bench_grpc_client.cc
    "${PROTO_OUT}/pipeline_fft_std.pb.cc"
    "${PROTO_OUT}/pipeline_fft_std.grpc.pb.cc"
)
add_dependencies(bench_grpc_client_std pipeline_proto_std_gen)
target_include_directories(bench_grpc_client_std PRIVATE
    "${PROTO_OUT}"
    "${DAQIRI_GPU_ROOT}/common"
)
target_compile_definitions(bench_grpc_client_std PRIVATE STANDARD_GRPC_ONLY)
target_link_libraries(bench_grpc_client_std PRIVATE
    grpc_stack
    signal_gen
)
# No grpc_direct_cpp, no -lgrpc_direct, no RPATH to cargo dir
