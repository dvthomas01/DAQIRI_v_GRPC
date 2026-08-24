#!/bin/sh
# Table B, taken properly.  Runs on the Spark; launch it detached.
#
# The published Table B (handoff 7l) compared an extbuf arm from the streaming
# loopback sweep against DAQiri rows from the headline sweep.  Those two
# harnesses do not send at the same rate, and scripts/pace_probe.sh showed that
# matters: at 16 KB extbuf posts cuFFT p50 5.5 to 6.7 us at paces 0, 25 and 100
# and 16.7 to 20.7 us at 400, while DAQiri holds 4.6 to 4.9 us throughout.  The
# old table therefore paired an unpaced extbuf with a 400 us paced DAQiri, and
# its 16 KB row changes sign once both arms are sent at the same rate.
#
# Pace 25 us is chosen because both arms are flat there.  At 1 MiB and 4 MiB it
# is well under the wire time anyway (168 and 671 us), so those sizes are
# link-limited and the pace does nothing; it only matters at 16 and 256 KB.
#
# base and opt ride along at no extra cost and refresh the headline table in the
# same thermal window, which is the only way its deltas are worth anything.
set -u
cd "$HOME/daqiri_gpu" || exit 1

export GITSHA="${GITSHA:-tableB}"
export SIZES="4096 65536 262144 1048576"
export ARMS="base opt daq extbuf"
export REPS="${REPS:-3}"
export PACE="${PACE:-25}"
export N="${N:-1000}"
export W="${W:-500}"
export OUT="${OUT:-data/tableB_interleaved.csv}"

exec bash scripts/headline_sweep.sh
