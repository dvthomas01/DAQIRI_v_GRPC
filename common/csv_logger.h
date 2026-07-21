#pragma once

#include "metrics.h"

#include <fstream>
#include <string>

// Writes one CSV row per BufferMetrics to a file.
// Header is written automatically on construction.
class CsvLogger {
public:
    explicit CsvLogger(const std::string& path);
    ~CsvLogger();

    // Non-copyable
    CsvLogger(const CsvLogger&) = delete;
    CsvLogger& operator=(const CsvLogger&) = delete;

    void log(const BufferMetrics& m);
    void flush();

private:
    std::ofstream file_;
    void write_header();
};
