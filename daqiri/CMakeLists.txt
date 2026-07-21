set(DAQIRI_DIR "$ENV{HOME}/daqiri" CACHE PATH "DAQiri SDK root")

# find_package(daqiri) doesn't work on the build-tree install on Spark
# (daqiriTargets.cmake lives in the CMakeFiles export cache, not beside Config).
# Link directly instead.

find_library(DAQIRI_LIB daqiri
    PATHS "${DAQIRI_DIR}/build/src"
    NO_DEFAULT_PATH REQUIRED)

find_library(YAML_CPP_LIB yaml-cpp
    PATHS "${DAQIRI_DIR}/build/src/third_party/yaml-cpp"
    NO_DEFAULT_PATH REQUIRED)

# ── Shared include + link helper ──────────────────────────────────────────────
set(DAQIRI_INCS
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${CMAKE_SOURCE_DIR}/fft"           # cufft_executor.h
    "${CMAKE_SOURCE_DIR}/common"        # util_sampler.h
    "${DAQIRI_DIR}/include"
    "${DAQIRI_DIR}/third_party/spdlog/include"
    "${DAQIRI_DIR}/third_party/yaml-cpp/include"
)
set(DAQIRI_LIBS
    ${DAQIRI_LIB}
    ${YAML_CPP_LIB}
    signal_gen
    csv_logger
    cufft_executor
    CUDA::cudart
    CUDA::cufft
    nvidia-ml           # NVML for GPU utilization in util_sampler.h
)
set(DAQIRI_RPATH
    "${DAQIRI_DIR}/build/src:${DAQIRI_DIR}/build/src/third_party/yaml-cpp"
)

# ── M3: session-init validation ───────────────────────────────────────────────
add_executable(bench_daqiri bench_daqiri.cc)
target_include_directories(bench_daqiri PRIVATE ${DAQIRI_INCS})
target_link_libraries(bench_daqiri PRIVATE ${DAQIRI_LIBS})
set_target_properties(bench_daqiri PROPERTIES
    BUILD_RPATH   "${DAQIRI_RPATH}"
    INSTALL_RPATH "${DAQIRI_RPATH}"
)

# ── M4: full pipeline (socket → H→D → cuFFT → metrics) ───────────────────────
add_executable(bench_daqiri_pipeline bench_daqiri_pipeline.cc)
target_include_directories(bench_daqiri_pipeline PRIVATE ${DAQIRI_INCS})
target_link_libraries(bench_daqiri_pipeline PRIVATE ${DAQIRI_LIBS})
set_target_properties(bench_daqiri_pipeline PROPERTIES
    BUILD_RPATH   "${DAQIRI_RPATH}"
    INSTALL_RPATH "${DAQIRI_RPATH}"
)
