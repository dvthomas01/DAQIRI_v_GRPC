add_library(cufft_executor STATIC cufft_executor.cu)
target_include_directories(cufft_executor PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(cufft_executor PUBLIC CUDA::cufft CUDA::cudart)
set_target_properties(cufft_executor PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
)

add_executable(fft_validate fft_validate.cc)
target_link_libraries(fft_validate PRIVATE cufft_executor signal_gen CUDA::cudart)

# Single-process placement ladder: times the same R2C plan over device memory,
# cudaHostAlloc'd pinned host, registered heap, registered /dev/shm, and
# registered huge pages.  No gRPC, no DAQiri, no network.
add_executable(bench_fft_memsrc bench_fft_memsrc.cc)
target_link_libraries(bench_fft_memsrc PRIVATE
    cufft_executor
    signal_gen
    CUDA::cudart
    rt          # shm_open lives in librt on older glibc
)
