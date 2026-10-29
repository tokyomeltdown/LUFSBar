#!/bin/zsh
# Builds the LoudnessMeter tests against the app's own LoudnessMeter.swift and
# the vendored libebur128, into a work folder outside the repository, and runs
# them. Each test file is a main.swift, so each is built on its own.
# meter_state also builds the app's MeterState.swift, with SystemAudioTap
# stood in for by meter_state_stub.swift.
#
# Usage: build_meter_tests.sh <work folder> [<LoudnessMeter.swift> [<MeterState.swift>]]
#   The second and third arguments build against other copies, for running
#   the same tests on the code from before a fix.
# Set ONLY=<test name> to build and run just one of them.
# Exits non-zero if any test fails (a crash counts as a failure).

set -u
W=$1
R=${0:A:h}/../LUFSBar
METER=${2:-$R/LoudnessMeter.swift}
STATE=${3:-$R/MeterState.swift}
mkdir -p $W
clang -c -Os -I $R/libebur128 $R/libebur128/ebur128.c -o $W/ebur128.o 2>/dev/null || { print "libebur128 did not build"; exit 2; }
printf '#include "ebur128.h"\n' > $W/bridge.h
for t in meter_failed_init meter_refresh meter_growth meter_mono; do
    [[ -n ${ONLY:-} && $t != $ONLY ]] && continue
    mkdir -p $W/$t && cp ${0:A:h}/$t.swift $W/$t/main.swift
    swiftc -O -import-objc-header $W/bridge.h -I $R/libebur128 $W/$t/main.swift $METER $W/ebur128.o -o $W/$t/run \
        > $W/$t/build.log 2>&1 || { cat $W/$t/build.log; print "$t did not build"; exit 2; }
done
if [[ -z ${ONLY:-} || $ONLY == meter_state ]]; then
    mkdir -p $W/meter_state && cp ${0:A:h}/meter_state.swift $W/meter_state/main.swift
    swiftc -O -import-objc-header $W/bridge.h -I $R/libebur128 $W/meter_state/main.swift ${0:A:h}/meter_state_stub.swift \
        $STATE $METER $W/ebur128.o -o $W/meter_state/run > $W/meter_state/build.log 2>&1 \
        || { cat $W/meter_state/build.log; print "meter_state did not build"; exit 2; }
fi

FAILED=0
run() {
    print -n "$*: "
    "$@" || { local s=$?; (( s > 128 )) && print "  crashed (signal $(( s - 128 )))"; FAILED=1; }
}
# B2: a sample rate libebur128 refuses must come back as nil, not a crash.
[[ -z ${ONLY:-} || $ONLY == meter_failed_init ]] && for rate in 0 3000000 48000; do run $W/meter_failed_init/run $rate; done
# M1: ten refreshes a second whatever the buffer size, and a number right after Reset.
[[ -z ${ONLY:-} || $ONLY == meter_refresh ]] && for c in "48000 512" "44100 512" "48000 2048" "48000 4096" "96000 128" "192000 256"; do run $W/meter_refresh/run ${=c}; done
# B1: a call must not get slower the longer the meter runs.
[[ -z ${ONLY:-} || $ONLY == meter_growth ]] && run $W/meter_growth/run 48000 512 30
# A mono device reads as a stereo one does.
[[ -z ${ONLY:-} || $ONLY == meter_mono ]] && for rate in 48000 44100; do run $W/meter_mono/run $rate; done
# What MeterState decides from what it reads: the menu bar after near silence,
# and which quiet counts as silence for the reset.
[[ -z ${ONLY:-} || $ONLY == meter_state ]] && for c in lag reset110 pause85 floor; do run $W/meter_state/run $c; done
exit $FAILED
