#!/bin/zsh
# Checks the reading on default outputs with more than one output stream, made
# for the test from two real devices and removed afterwards:
#
#   1  an aggregate of a 2-channel and a multichannel device (output streams
#      [2, n]) with the stereo pair inside the second stream (3-4): -18.0
#   2  the same with the stereo pair across the two streams (2-3): -18.0
#      (before the fix only stream 0 was tapped, and the tone read -21.0)
#   4  the same with the left side in the later stream (3-2): -18.0
#   3  a Multi-Output Device of the two as the default output: -18.0
#
# Usage: streams.sh <LUFSBar.app> <tone.wav> "<2-channel device>" "<multichannel device>"
# Devices by name or UID. Needs default_output, stereo_channels and aggregate
# (built from this folder) in $BIN. Plays the tone on the default output.
# Puts back the default output and removes the devices it made on exit.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; TWO=$3; MULTI=$4
BIN=${BIN:?set BIN to the folder holding default_output, stereo_channels and aggregate}
for tool in default_output stereo_channels aggregate; do
    [[ -x $BIN/$tool ]] || { print "no $tool in $BIN: build it from tests/$tool.swift"; exit 2; }
done
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
quit_app() {
    killall LUFSBar 2>/dev/null
    for _ in {1..10}; do pgrep -x LUFSBar >/dev/null || return 0; sleep 1; done
}

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
if [[ $(defaults read com.tokyomeltdown.lufsbar LUFSBar.hasCompletedFirstLaunchTapStart 2>/dev/null) != 1 ]]; then
    print "start metering once by hand first (first launch waits for a click)"; exit 2
fi
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }
WORK=$(mktemp -d)
MADE=
TEST_UIDS=(com.tokyomeltdown.lufsbar.test.LUFSBarTestAggregate com.tokyomeltdown.lufsbar.test.LUFSBarTestMultiOutput)
finish() {
    quit_app
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
    [[ -n $MADE ]] && kill $MADE 2>/dev/null && wait $MADE 2>/dev/null
    # Whatever the helper did on its way out, the devices are not left behind.
    for uid in $TEST_UIDS; do "$BIN/aggregate" destroy $uid; done
    rm -rf $WORK
}
# Only now: on the way out it quits LUFSBar, which above is someone's own copy.
# Before the devices are looked up, which changes the default output.
trap finish EXIT
# The devices' UIDs, read by making each the default output in turn.
uid_of() { "$BIN/default_output" "$1" >/dev/null && "$BIN/default_output" -u }
TWO_UID=$(uid_of "$TWO") || { print "cannot select \"$TWO\""; exit 2; }
MULTI_UID=$(uid_of "$MULTI") || { print "cannot select \"$MULTI\""; exit 2; }
"$BIN/default_output" "$ORIGINAL" >/dev/null

# Makes the device ($1 stacked, $2 name) and makes it the default output.
make_device() {
    [[ -n $MADE ]] && { kill $MADE 2>/dev/null; wait $MADE 2>/dev/null; MADE=; }
    "$BIN/aggregate" destroy com.tokyomeltdown.lufsbar.test.$2
    "$BIN/aggregate" $1 $2 $TWO_UID $MULTI_UID > $WORK/$2.uid & MADE=$!
    local uid=
    for _ in {1..20}; do uid=$(head -1 $WORK/$2.uid 2>/dev/null); [[ -n $uid ]] && break; sleep 0.25; done
    [[ $uid == com.tokyomeltdown.* ]] || { print "cannot test: the $2 device was not made ($uid)"; exit 2; }
    "$BIN/default_output" "$uid" >/dev/null || { print "cannot test: cannot select the $2 device"; exit 2; }
    DEVICE=$uid
}

# The most common Momentary of the level lines after the tone has settled.
measure() {
    local since=$(mark)
    open "$APP"
    applog_wait "$since" 20 "capture started" || { print "none"; quit_app; return; }
    afplay "$TONE"; afplay "$TONE"
    local m=$(applog_since "$since" | grep " M=" | tail -6 | grep -o " M=-*[0-9.]*" | cut -c4- \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    quit_app
    print ${m:-none}
}
check() {
    local n=$1 what=$2 m=$3
    if [[ $m != none ]] && (( m >= -18.2 && m <= -17.8 )); then
        result PASS "$n $what: M $m"
    else
        result FAIL "$n $what: M $m (want -18.0)"
    fi
}

make_device 0 LUFSBarTestAggregate
# Cases 1, 2 and 4 need a 2-channel first stream and a second one of 4 or more.
LAYOUT=$("$BIN/stereo_channels" "$DEVICE" | grep -o "streams=.*")
[[ $LAYOUT =~ '^streams=\[2, ([4-9]|[1-9][0-9])\]$' ]] || { print "cannot test: the aggregate's streams are $LAYOUT"; exit 2; }
"$BIN/stereo_channels" "$DEVICE" 3 4 >/dev/null || { print "cannot test: cannot set the stereo pair"; exit 2; }
check 1 "stereo pair inside the second stream (3-4)" $(measure)
"$BIN/stereo_channels" "$DEVICE" 2 3 >/dev/null || { print "cannot test: cannot set the stereo pair"; exit 2; }
check 2 "stereo pair across two streams (2-3)" $(measure)
# Left in the later stream: the only layout where the order the taps are listed
# in and the order of the device's streams disagree.
"$BIN/stereo_channels" "$DEVICE" 3 2 >/dev/null || { print "cannot test: cannot set the stereo pair"; exit 2; }
check 4 "stereo pair across two streams, left in the later one (3-2)" $(measure)

make_device 1 LUFSBarTestMultiOutput
check 3 "Multi-Output Device" $(measure)

exit $FAILED
