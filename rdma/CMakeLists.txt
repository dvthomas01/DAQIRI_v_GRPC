# Phase 2: the minimal RDMA data path.
#
# Only the receiver is built here.  The sender runs on the NI PXIe-8881, which
# has no CUDA and is not part of this CMake tree; it is compiled there directly
# with g++ (see the header comment in rdma_fft_client.cc).

find_library(IBVERBS_LIBRARY NAMES ibverbs)
find_path(IBVERBS_INCLUDE_DIR NAMES infiniband/verbs.h)

if(NOT IBVERBS_LIBRARY OR NOT IBVERBS_INCLUDE_DIR)
    message(STATUS "libibverbs not found; skipping the Phase 2 RDMA targets")
    return()
endif()

add_executable(rdma_fft_server rdma_fft_server.cu)
target_include_directories(rdma_fft_server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${IBVERBS_INCLUDE_DIR}
)
target_link_libraries(rdma_fft_server PRIVATE
    cufft_executor
    signal_gen
    CUDA::cudart
    ${IBVERBS_LIBRARY}
)
