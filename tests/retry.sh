#!/bin/zsh
# Checks how a tap that cannot be built is tried again, using the switches in
# SystemAudioTap (LUFSBAR_FAIL_START_AT / _TIMES, LUFSBAR_METER_RATE / _TIMES).
#
#   1  every attempt fails while the default output keeps changing (a display
#      or a Bluetooth device coming and going): the access panel still comes
#      after the failures, rather than each change starting the count again
#   2  the default output's UID cannot be read once: tried again, and it starts
#   3  five attempts fail: the panel comes, the attempts go on behind it, and
#      when one goes through the panel goes away
#   4  the meter's rate reads as 5 Hz once (a device going away): the tap is
#      built again and the meter comes, instead of "--" for good
#   5  a device at 1,536,000 Hz gets a meter (libebur128 takes up to
#      2,822,400 Hz)
#   6  failures from an episode that recovered are not counted in the next:
#      three fail, the fourth starts (nothing playing, so no meter), and one
#      failure on a later output change is the first in a row, with no panel
#   7  a meter that cannot be built (the rate always reads 5 Hz) is asked for
#      again, without rebuilding the tap or showing the access panel
#   8  a meter request left from the tap before a rebuild is dropped, not
#      served against the new tap (LUFSBAR_METER_REQUEST_DELAY_MS holds it
#      back while the default output changes)
#   9  reading which device is the default output fails once: tried again,
#      and it starts (it used to be taken for "no output" and waited for good)
#
# Usage: retry.sh <LUFSBar.app> <tone.wav> "<device A>" "<device B>"
# Needs default_output and tone_to_device (built from this folder) in $BIN.
# Cases 1, 6 and 8 switch the default output between A and B; it is put back
# afterwards. Plays the tone on the default output (8: on A and B). Case 6
# needs nothing else playing to A or B.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; A=$3; B=$4
BIN=${BIN:?set BIN to the folder holding default_output}
for tool in default_output tone_to_device; do
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
# On the very first launch the app waits for a click before it taps anything.
if [[ $(defaults read com.tokyomeltdown.lufsbar LUFSBar.hasCompletedFirstLaunchTapStart 2>/dev/null) != 1 ]]; then
    print "start metering once by hand first (first launch waits for a click)"; exit 2
fi
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }
finish() {
    quit_app
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
}
# Only now: on the way out it quits LUFSBar, which above is someone's own copy.
trap finish EXIT
for d in $A $B; do "$BIN/default_output" "$d" >/dev/null || { print "cannot select \"$d\""; exit 2; }; done
"$BIN/default_output" "$ORIGINAL" >/dev/null

# 1. Every attempt fails; the default output changes every 0.5 s for 8 s.
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=tap "$APP"
# Changing at once, not after waiting for the first failure in the log: that
# wait polls every 2 s, and by then the first three failures (3 s) have gone
# by without a change, so the panel came on any build.
for i in {1..16}; do
    "$BIN/default_output" "$( (( i % 2 )) && print $A || print $B )" >/dev/null
    sleep 0.5
done
# Read while the changes are still that recent: before the fix, the count only
# got through once they stopped.
LOGTEXT=$(applog_since "$SINCE")
quit_app
"$BIN/default_output" "$ORIGINAL" >/dev/null
FAILS=$(print -r -- $LOGTEXT | grep -c "failing on purpose at tap")
CHANGES=$(print -r -- $LOGTEXT | grep -c "default output device changed")
if (( FAILS == 0 || CHANGES < 8 )); then
    print "cannot test 1: $FAILS failed attempts, $CHANGES default output changes seen (want 8 or more)"; exit 2
elif print -r -- $LOGTEXT | grep -q "showing the system audio access error"; then
    result PASS "1 with the default output changing, the panel came after the failures ($FAILS attempts)"
else
    result FAIL "1 with the default output changing, $FAILS failed attempts and no panel"
fi

# 2. The UID cannot be read once.
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=uid --env LUFSBAR_FAIL_START_TIMES=1 "$APP"
STARTED=no
applog_wait "$SINCE" 12 "capture started" && STARTED=yes
LOGTEXT=$(applog_since "$SINCE")
quit_app
# The failure has to have happened, or this passes on a build without the switch.
if ! print -r -- $LOGTEXT | grep -q "failing on purpose at uid"; then
    result FAIL "2 the UID read was never made to fail (no LUFSBAR_FAIL_START_AT=uid in this build?)"
elif [[ $STARTED == yes ]]; then
    result PASS "2 an unreadable UID was tried again, and capture started"
else
    result FAIL "2 an unreadable UID: no capture within 12 s (not tried again)"
fi

# 3. Five attempts fail at the aggregate.
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=aggregate --env LUFSBAR_FAIL_START_TIMES=5 "$APP"
STARTED=no
applog_wait "$SINCE" 45 "capture started" && STARTED=yes
LOGTEXT=$(applog_since "$SINCE")
quit_app
PANEL=$(print -r -- $LOGTEXT | grep -c "showing the system audio access error")
CLEARED=$(print -r -- $LOGTEXT | grep -c "the system audio access error is cleared")
if [[ $STARTED == yes ]] && (( PANEL == 1 && CLEARED == 1 )); then
    result PASS "3 after five failures the panel came, the attempts went on, and it went away when one went through"
else
    result FAIL "3 after five failures: panel shown $PANEL, capture started: $STARTED, panel cleared $CLEARED (want 1, yes, 1)"
fi

# 4 and 5. The meter's rate, with the tone playing.
# $3: the rate the meter must be built at, as a grep pattern; $4: the rate the
# switch makes the app read, which its log has to show it read.
meter_case() {
    local n=$1 what=$2 want=$3 forced=$4; shift 4
    local since=$(mark)
    open "$@" "$APP"
    applog_wait "$since" 30 "capture started" || { result FAIL "$n $what: capture did not start"; quit_app; return; }
    afplay "$TONE"; afplay "$TONE"
    local logtext=$(applog_since "$since")
    quit_app
    local built=$(print -r -- $logtext | sed -n 's/.*LoudnessMeter init sampleRate=\([0-9]*\) .*/\1/p' | tr '\n' ' ')
    if ! print -r -- $logtext | grep -q "reading the meter's rate as $forced"; then
        result FAIL "$n $what: the rate was never read as $forced (no LUFSBAR_METER_RATE in this build?)"
    elif print -r -- $logtext | grep -q "LoudnessMeter init sampleRate=$want "; then
        result PASS "$n $what: a meter was built (at ${built% })"
    else
        result FAIL "$n $what: no meter at the rate wanted (built: ${built:-none})"
    fi
}
# 4: any real rate (the device's own), not 5.
meter_case 4 "the rate read as 5 Hz once" "[0-9][0-9][0-9][0-9][0-9]*" 5 --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=1
meter_case 5 "a device at 1,536,000 Hz" 1536000 1536000 --env LUFSBAR_METER_RATE=1536000

# 6. Attempts 1-3 and 5 fail. The fourth starts with nothing playing, then the
# default output changes, and the fifth fails.
"$BIN/default_output" "$A" >/dev/null
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=tap --env LUFSBAR_FAIL_START_ATTEMPTS=1,2,3,5 "$APP"
applog_wait "$SINCE" 15 "capture started" || { print "cannot test 6: capture did not start"; exit 2; }
sleep 2
MID=$(mark)
"$BIN/default_output" "$B" >/dev/null
applog_wait "$MID" 15 "capture started"
LOGTEXT=$(applog_since "$SINCE")
quit_app
"$BIN/default_output" "$ORIGINAL" >/dev/null
print -r -- $LOGTEXT | grep -q "LoudnessMeter init" && { print "cannot test 6: something played (a meter was built)"; exit 2; }
AFTER=$(applog_since "$MID")
if ! print -r -- $AFTER | grep -q "failing on purpose at tap"; then
    result FAIL "6 the build after the output change was never made to fail (no LUFSBAR_FAIL_START_ATTEMPTS in this build?)"
elif print -r -- $AFTER | grep -q "(1 failed in a row)" && ! print -r -- $LOGTEXT | grep -q "showing the system audio access error"; then
    result PASS "6 a failure after a recovered episode was the first in a row, with no panel"
else
    result FAIL "6 a failure after a recovered episode: $(print -r -- $AFTER | grep -o '([0-9]* failed in a row)' | head -1), panel shown $(print -r -- $LOGTEXT | grep -c 'showing the system audio access error') (want (1 failed in a row) and 0)"
fi

# 7. The meter's rate always reads 5 Hz, with the tone playing.
SINCE=$(mark)
open --env LUFSBAR_METER_RATE=5 "$APP"
applog_wait "$SINCE" 30 "capture started" || { result FAIL "7 capture did not start"; quit_app; }
afplay "$TONE"; afplay "$TONE"
LOGTEXT=$(applog_since "$SINCE")
quit_app
TAPS=$(print -r -- $LOGTEXT | grep -c "tap created")
PANEL=$(print -r -- $LOGTEXT | grep -c "showing the system audio access error")
ASKED=$(print -r -- $LOGTEXT | grep -c "reading the meter's rate as 5")
if (( ASKED >= 2 && TAPS == 1 && PANEL == 0 )); then
    result PASS "7 a meter that could not be built was asked for $ASKED times, on the one tap, with no panel"
else
    result FAIL "7 a meter that could not be built: asked $ASKED times, $TAPS taps built, panel shown $PANEL (want 2+, 1, 0)"
fi

# 8. The first request waits 3 s; the default output changes 1.5 s in, so the
# request belongs to a tap that is gone when it is taken up. Read as 5 Hz, it
# used to count as the new tap's failure and rebuild it once more.
"$BIN/default_output" "$A" >/dev/null
"$BIN/tone_to_device" "$A" 12 "$TONE" >/dev/null & PA=$!
"$BIN/tone_to_device" "$B" 12 "$TONE" >/dev/null & PB=$!
sleep 1
SINCE=$(mark)
open --env LUFSBAR_METER_REQUEST_DELAY_MS=3000 --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=1 "$APP"
sleep 1.5
"$BIN/default_output" "$B" >/dev/null
sleep 8
LOGTEXT=$(applog_since "$SINCE")
quit_app
wait $PA $PB 2>/dev/null
"$BIN/default_output" "$ORIGINAL" >/dev/null
TAPS=$(print -r -- $LOGTEXT | grep -c "tap created")
CHANGES=$(print -r -- $LOGTEXT | grep -c "default output device changed")
DROPPED=$(print -r -- $LOGTEXT | grep -c "dropping a meter request from an earlier tap")
if (( CHANGES != 1 )); then
    print "cannot test 8: $CHANGES default output changes seen (want 1)"; exit 2
elif (( TAPS == 2 && DROPPED >= 1 )); then
    result PASS "8 the request from the earlier tap was dropped, and only the change rebuilt the tap"
else
    result FAIL "8 a request from the earlier tap: $TAPS taps built, $DROPPED dropped (want 2 and 1 or more)"
fi

# 9. Reading the default output fails once.
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=defaultdevice --env LUFSBAR_FAIL_START_TIMES=1 "$APP"
STARTED=no
applog_wait "$SINCE" 12 "capture started" && STARTED=yes
LOGTEXT=$(applog_since "$SINCE")
quit_app
if ! print -r -- $LOGTEXT | grep -q "failing on purpose at defaultdevice"; then
    result FAIL "9 the read was never made to fail (no LUFSBAR_FAIL_START_AT=defaultdevice in this build?)"
elif [[ $STARTED == yes ]]; then
    result PASS "9 a failed read of the default output was tried again, and capture started"
else
    result FAIL "9 a failed read of the default output: no capture within 12 s (taken for no output)"
fi

exit $FAILED
