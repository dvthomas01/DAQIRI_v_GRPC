#!/bin/sh
# Build the pre-stage-timing DAQiri binary alongside the current one.
#
# The claim under test is that rebuilding bench_daqiri_roce_pipeline is what
# moved its 4 MiB transform from 64.13 us (Table B) to 58.37 us (stage sweep).
# The pre-change binary and its object file were both overwritten by the
# rebuild on Aug 24, and the source was untracked before commit 035d8e8, so
# neither can be recovered. What can be done is to reconstruct the source by
# removing the eleven additions, build it with the same toolchain and the same
# CMake configuration, and run the two head to head in one rotation.
#
# Procedure: swap the source, build, rename the artifact, swap back, rebuild.
# This uses the existing target rather than adding a new one, so both binaries
# come out of an identical compile and link line.
set -eu
cd "$HOME/daqiri_gpu"

SRC=daqiri/bench_daqiri_roce_pipeline.cc
BIN=build/daqiri/bench_daqiri_roce_pipeline

cp "$SRC" /tmp/daq_new.cc
python3 scripts/strip_stage_timing.py /tmp/daq_new.cc /tmp/daq_pre.cc

echo "--- building PRE ---"
cp /tmp/daq_pre.cc "$SRC"
cmake --build build --parallel 16 --target bench_daqiri_roce_pipeline
cp "$BIN" "${BIN}_pre"

echo "--- restoring and rebuilding CURRENT ---"
cp /tmp/daq_new.cc "$SRC"
cmake --build build --parallel 16 --target bench_daqiri_roce_pipeline

echo "--- verifying the two differ in the expected way ---"
if grep -qa -- '--stage-timing' "${BIN}_pre"; then
    echo "ABORT: the pre binary still advertises --stage-timing."
    exit 1
fi
if ! grep -qa -- '--stage-timing' "$BIN"; then
    echo "ABORT: the current binary lost --stage-timing."
    exit 1
fi
ls -la "$BIN" "${BIN}_pre"
echo OK
