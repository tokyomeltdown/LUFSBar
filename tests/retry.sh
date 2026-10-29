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
#
# Usage: retry.sh <LUFSBar.app> <tone.wav> "<device A>" "<device B>"
# Needs default_output (built from this folder) in $BIN. Case 1 switches the
# default output between A and B; it is put back afterwards. Plays the tone on
# the default output.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; A=$3; B=$4
BIN=${BIN:?set BIN to the folder holding default_output}
[[ -x $BIN/default_output ]] || { print "no default_output in $BIN: build it from tests/default_output.swift"; exit 2; }
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
quit_app() {
    killall LUFSBar 2>/dev/null
    for _ in {1..10}; do pgrep -x LUFSBar >/dev/null || return 0; sleep 1; done
}

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
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
    result FAIL "1 could not be set up: $FAILS failed attempts, $CHANGES default output changes seen (want 8 or more)"
elif print -r -- $LOGTEXT | grep -q "showing the system audio access error"; then
    result PASS "1 with the default output changing, the panel came after the failures ($FAILS attempts)"
else
    result FAIL "1 with the default output changing, $FAILS failed attempts and no panel"
fi

# 2. The UID cannot be read once.
SINCE=$(mark)
open --env LUFSBAR_FAIL_START_AT=uid --env LUFSBAR_FAIL_START_TIMES=1 "$APP"
if applog_wait "$SINCE" 12 "capture started"; then
    result PASS "2 an unreadable UID was tried again, and capture started"
else
    result FAIL "2 an unreadable UID: no capture within 12 s (not tried again)"
fi
quit_app

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
# $3: the rate the meter must be built at, as a grep pattern.
meter_case() {
    local n=$1 what=$2 want=$3; shift 3
    local since=$(mark)
    open "$@" "$APP"
    applog_wait "$since" 15 "capture started" || { result FAIL "$n $what: capture did not start"; quit_app; return; }
    afplay "$TONE"; afplay "$TONE"
    local logtext=$(applog_since "$since")
    quit_app
    local built=$(print -r -- $logtext | sed -n 's/.*LoudnessMeter init sampleRate=\([0-9]*\) .*/\1/p' | tr '\n' ' ')
    if print -r -- $logtext | grep -q "LoudnessMeter init sampleRate=$want "; then
        result PASS "$n $what: a meter was built (at ${built% })"
    else
        result FAIL "$n $what: no meter at the rate wanted (built: ${built:-none})"
    fi
}
# 4: any real rate (the device's own), not 5.
meter_case 4 "the rate read as 5 Hz once" "[0-9][0-9][0-9][0-9][0-9]*" --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=1
meter_case 5 "a device at 1,536,000 Hz" 1536000 --env LUFSBAR_METER_RATE=1536000

exit $FAILED
