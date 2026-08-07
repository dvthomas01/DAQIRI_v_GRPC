cmake_minimum_required(VERSION 3.20)
project(daqiri_gpu_fft LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Build for the GPU actually present at configure time.  This was hard-coded to
# 90 (Hopper) but spark-ac69 is a GB10 Grace-Blackwell at compute capability
# 12.1, so sm_90 kernels had no matching image and every launch silently failed
# with cudaErrorNoKernelImageForDevice.  cuFFT hid the problem because NVIDIA
# ships fat binaries.  Override with -DCMAKE_CUDA_ARCHITECTURES=XX to cross-build.
set(CMAKE_CUDA_ARCHITECTURES native CACHE STRING "CUDA architectures")

find_package(CUDAToolkit REQUIRED)

# Phase 1 — no transport yet
add_subdirectory(common)
add_subdirectory(fft)

# Phase 1 M3+ — DAQiri transport
set(DAQIRI_DIR "$ENV{HOME}/daqiri" CACHE PATH "DAQiri SDK root")
add_subdirectory(daqiri)

# Phase 2 — gRPC Direct transport (uncomment when ready)
# set(GRPC_DIRECT_DIR "$ENV{HOME}/grpc-direct" CACHE PATH "grpc-direct source")
# add_subdirectory("${GRPC_DIRECT_DIR}" grpc-direct-build)
# add_subdirectory(grpc_direct)
