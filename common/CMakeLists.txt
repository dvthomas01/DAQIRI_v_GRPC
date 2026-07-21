add_library(signal_gen STATIC signal_gen.cc)
target_include_directories(signal_gen PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_library(csv_logger STATIC csv_logger.cc)
target_include_directories(csv_logger PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(csv_logger PUBLIC signal_gen)   # csv_logger.h includes metrics.h

# metrics.h and buffer_pool.h are header-only — expose via an interface target
# so any consumer can do: target_link_libraries(foo PRIVATE common_headers)
add_library(common_headers INTERFACE)
target_include_directories(common_headers INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})
