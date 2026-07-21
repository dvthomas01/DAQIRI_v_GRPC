#include "csv_logger.h"

#include <stdexcept>

CsvLogger::CsvLogger(const std::string& path)
    : file_(path, std::ios::out | std::ios::trunc)
{
    if (!file_.is_open()) {
        throw std::runtime_error("CsvLogger: cannot open file: " + path);
    }
    write_header();
}

CsvLogger::~CsvLogger() {
    if (file_.is_open()) file_.close();
}

void CsvLogger::write_header() {
    file_ << "e2e_latency_us"
          << ",transfer_latency_us"
          << ",fft_exec_us"
          << ",samples_per_sec"
          << ",buffers_per_sec"
          << ",mb_per_sec"
          << ",cpu_util_pct"
          << ",gpu_util_pct"
          << ",buffer_size_samples"
          << ",dropped_buffers"
          << ",wire_latency_us"
          << "\n";
}

void CsvLogger::log(const BufferMetrics& m) {
    file_ << m.e2e_latency_us
          << ',' << m.transfer_latency_us
          << ',' << m.fft_exec_us
          << ',' << m.samples_per_sec
          << ',' << m.buffers_per_sec
          << ',' << m.mb_per_sec
          << ',' << m.cpu_util_pct
          << ',' << m.gpu_util_pct
          << ',' << m.buffer_size_samples
          << ',' << m.dropped_buffers
          << ',' << m.wire_latency_us
          << '\n';
}

void CsvLogger::flush() {
    file_.flush();
}
