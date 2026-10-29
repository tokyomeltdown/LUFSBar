#!/bin/zsh
# Checks how a tap that cannot be built, or a meter that cannot be built, is
# tried again, using the test switches in SystemAudioTap:
#   LUFSBAR_FAIL_START_AT = defaultdevice | uid | tap | aggregate | ioproc | devicestart
#   LUFSBAR_FAIL_START_TIMES = n, LUFSBAR_FAIL_START_ATTEMPTS = 1,2,3,5
#   LUFSBAR_NO_OUTPUT_AT_ATTEMPT = n, LUFSBAR_METER_RATE = Hz (+ _TIMES = n),
#   LUFSBAR_METER_REQUEST_DELAY_MS = n
#
#   1  every attempt fails while the default output keeps changing (a display
#      or a Bluetooth device coming and going): the access panel still comes
#      after the failures, rather than each change starting the count again
#   2  the default output's UID cannot be read once: tried again, and it starts
#   3  five attempts fail: the panel comes, the attempts go on behind it, and
#      when one goes through the panel goes away
#   4  the meter's rate reads as 5 Hz once (a device going away): the meter is
#      asked for again on the same tap and comes, instead of "--" for good
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
#  10  a meter that fails six times in a row comes as soon as the rate reads
#      again: it is asked for every second, not on the build schedule (which
#      would have left "--" for 18 s with the audio playing)
#  11  three builds fail, then there is no default output for a moment: the
#      next failure, on the output that comes back, is the first in a row
#  12  five builds fail (the panel shows), then there is no default output:
#      the panel goes away, since nothing is failing any more
#
# Usage: retry.sh <LUFSBar.app> <tone.wav> "<device A>" "<device B>"
# Needs default_output and tone_to_device (built from this folder) in $BIN.
# Cases 1, 6, 8, 11 and 12 switch the default output between A and B; it is put
# back afterwards. Plays the tone on the default output (8: on A and B).
# Cases 6, 11 and 12 need nothing else playing to A or B.
# Exits 1 if any case failed, 2 if none failed but one could not be tested.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; A=$3; B=$4
BIN=${BIN:?set BIN to the folder holding default_output and tone_to_device}
for tool in default_output tone_to_device; do
    [[ -x $BIN/$tool ]] || { print "no $tool in $BIN: build it from tests/$tool.swift"; exit 2; }
done
FAILED=0
CANNOT=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
# A case whose set-up did not happen: reported, and the rest still run.
cannot() { print "cannot test $1"; CANNOT=1; }
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

panels() { print -r -- $1 | grep -c "showing the system audio access error" }

# 1. Every attempt fails; the default output changes every 0.5 s for 8 s.
case_1() {
    local since=$(mark)
    open --env LUFSBAR_FAIL_START_AT=tap "$APP"
    # Changing at once, not after waiting for the first failure in the log:
    # that wait polls every 2 s, and by then the first three failures (3 s)
    # have gone by without a change, so the panel came on any build.
    for i in {1..16}; do
        "$BIN/default_output" "$( (( i % 2 )) && print $A || print $B )" >/dev/null
        sleep 0.5
    done
    # Read while the changes are still that recent: before the fix, the count
    # only got through once they stopped.
    local logtext=$(applog_since "$since")
    quit_app
    "$BIN/default_output" "$ORIGINAL" >/dev/null
    local fails=$(print -r -- $logtext | grep -c "failing on purpose at tap")
    local changes=$(print -r -- $logtext | grep -c "default output device changed")
    if (( fails == 0 || changes < 8 )); then
        cannot "1: $fails failed attempts, $changes default output changes seen (want 8 or more)"
    elif (( $(panels $logtext) > 0 )); then
        result PASS "1 with the default output changing, the panel came after the failures ($fails attempts)"
    else
        result FAIL "1 with the default output changing, $fails failed attempts and no panel"
    fi
}

# 2 and 9. One read fails at <point> once; it has to be tried again and start.
fail_once_case() {
    local n=$1 point=$2 what=$3
    local since=$(mark)
    open --env LUFSBAR_FAIL_START_AT=$point --env LUFSBAR_FAIL_START_TIMES=1 "$APP"
    local started=no
    applog_wait "$since" 12 "capture started" && started=yes
    local logtext=$(applog_since "$since")
    quit_app
    # The failure has to have happened, or this passes on a build without the switch.
    if ! print -r -- $logtext | grep -q "failing on purpose at $point"; then
        result FAIL "$n the $what was never made to fail (no LUFSBAR_FAIL_START_AT=$point in this build?)"
    elif [[ $started == yes ]]; then
        result PASS "$n a failed $what was tried again, and capture started"
    else
        result FAIL "$n a failed $what: no capture within 12 s (not tried again)"
    fi
}

# 3. Five attempts fail at the aggregate.
case_3() {
    local since=$(mark)
    open --env LUFSBAR_FAIL_START_AT=aggregate --env LUFSBAR_FAIL_START_TIMES=5 "$APP"
    local started=no
    applog_wait "$since" 45 "capture started" && started=yes
    local logtext=$(applog_since "$since")
    quit_app
    local panel=$(panels $logtext)
    local cleared=$(print -r -- $logtext | grep -c "the system audio access error is cleared")
    if [[ $started == yes ]] && (( panel == 1 && cleared == 1 )); then
        result PASS "3 after five failures the panel came, the attempts went on, and it went away when one went through"
    else
        result FAIL "3 after five failures: panel shown $panel, capture started: $started, panel cleared $cleared (want 1, yes, 1)"
    fi
}

# Launches with the given switches, waits for capture, plays the tone twice
# (10 s) and puts the log in TONE_LOG; returns non-zero if capture never started.
run_with_tone() {
    local since=$(mark)
    TONE_LOG=
    open "$@" "$APP"
    applog_wait "$since" 30 "capture started" || { quit_app; return 1; }
    afplay "$TONE"; afplay "$TONE"
    TONE_LOG=$(applog_since "$since")
    quit_app
}

# 4 and 5. The meter's rate, with the tone playing.
# $3: the rate the meter must be built at, as a grep pattern; $4: the rate the
# switch makes the app read, which its log has to show it read.
meter_case() {
    local n=$1 what=$2 want=$3 forced=$4; shift 4
    run_with_tone "$@" || { result FAIL "$n $what: capture did not start"; return; }
    local built=$(print -r -- $TONE_LOG | sed -n 's/.*LoudnessMeter init sampleRate=\([0-9]*\) .*/\1/p' | tr '\n' ' ')
    if ! print -r -- $TONE_LOG | grep -q "reading the meter's rate as $forced"; then
        result FAIL "$n $what: the rate was never read as $forced (no LUFSBAR_METER_RATE in this build?)"
    elif print -r -- $TONE_LOG | grep -q "LoudnessMeter init sampleRate=$want "; then
        result PASS "$n $what: a meter was built (at ${built% })"
    else
        result FAIL "$n $what: no meter at the rate wanted (built: ${built:-none})"
    fi
}

# 6, 11. The default output changes from A to B after the app reached <ready>
# with nothing playing; the build on B fails. Wants it to be the first failure
# in a row, with no panel shown at any point.
episode_case() {
    local n=$1 ready=$2 what=$3; shift 3
    "$BIN/default_output" "$A" >/dev/null
    local since=$(mark)
    open "$@" "$APP"
    if ! applog_wait "$since" 15 "$ready"; then
        quit_app; "$BIN/default_output" "$ORIGINAL" >/dev/null
        cannot "$n: never reached \"$ready\""; return
    fi
    sleep 2
    local mid=$(mark)
    "$BIN/default_output" "$B" >/dev/null
    sleep 3
    local logtext=$(applog_since "$since")
    local after=$(applog_since "$mid")
    quit_app
    "$BIN/default_output" "$ORIGINAL" >/dev/null
    if print -r -- $logtext | grep -q "LoudnessMeter init"; then
        cannot "$n: something played (a meter was built)"
    elif ! print -r -- $after | grep -q "failing on purpose at tap"; then
        result FAIL "$n the build after the output change was never made to fail (switches missing in this build?)"
    elif print -r -- $after | grep -q "trying again in .* (1 failed in a row)" && (( $(panels $logtext) == 0 )); then
        result PASS "$n $what: the failure after it was the first in a row, with no panel"
    else
        result FAIL "$n $what: the failure after it was $(print -r -- $after | grep -o 'trying again in .* failed in a row)' | head -1), panel shown $(panels $logtext) (want 1 failed in a row, and 0)"
    fi
}

# 7. The meter's rate always reads 5 Hz, with the tone playing.
case_7() {
    run_with_tone --env LUFSBAR_METER_RATE=5 || { result FAIL "7 capture did not start"; return; }
    local taps=$(print -r -- $TONE_LOG | grep -c "tap created")
    local asked=$(print -r -- $TONE_LOG | grep -c "reading the meter's rate as 5")
    local panel=$(panels $TONE_LOG)
    if (( asked >= 2 && taps == 1 && panel == 0 )); then
        result PASS "7 a meter that could not be built was asked for $asked times, on the one tap, with no panel"
    else
        result FAIL "7 a meter that could not be built: asked $asked times, $taps taps built, panel shown $panel (want 2+, 1, 0)"
    fi
}

# 8. The first meter request waits 8 s; the default output changes as soon as
# capture has started, so the request belongs to a tap that is gone when it is
# taken up. Read as 5 Hz, it used to count as the new tap's failure and
# rebuild it once more.
case_8() {
    "$BIN/default_output" "$A" >/dev/null
    "$BIN/tone_to_device" "$A" 30 "$TONE" >/dev/null & local pa=$!
    "$BIN/tone_to_device" "$B" 30 "$TONE" >/dev/null & local pb=$!
    sleep 1
    local since=$(mark)
    open --env LUFSBAR_METER_REQUEST_DELAY_MS=8000 --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=1 "$APP"
    local ok=yes
    applog_wait "$since" 6 "capture started" || ok=no
    # The tone is already playing to A, so its first callback (and request) came
    # with the start; the request is taken up 8 s later, after this change.
    sleep 0.5
    "$BIN/default_output" "$B" >/dev/null
    sleep 14
    local logtext=$(applog_since "$since")
    quit_app
    kill $pa $pb 2>/dev/null; wait $pa $pb 2>/dev/null
    "$BIN/default_output" "$ORIGINAL" >/dev/null
    local taps=$(print -r -- $logtext | grep -c "tap created")
    local changes=$(print -r -- $logtext | grep -c "default output device changed")
    local dropped=$(print -r -- $logtext | grep -c "dropping a meter request from an earlier tap")
    if [[ $ok == no ]] || (( changes != 1 )); then
        cannot "8: capture started in time: $ok, $changes default output changes seen (want yes, 1)"
    elif (( taps == 2 && dropped >= 1 )); then
        result PASS "8 the request from the earlier tap was dropped, and only the change rebuilt the tap"
    else
        result FAIL "8 a request from the earlier tap: $taps taps built, $dropped dropped (want 2 and 1 or more)"
    fi
}

# 10. The meter fails six times, then the rate reads again.
case_10() {
    run_with_tone --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=6 \
        || { result FAIL "10 capture did not start"; return; }
    local asked=$(print -r -- $TONE_LOG | grep -c "reading the meter's rate as 5")
    if (( asked < 6 )) && ! print -r -- $TONE_LOG | grep -q "LoudnessMeter init"; then
        result FAIL "10 the meter was asked for $asked times in 10 s and never came (want 6 refused, then a meter)"
    elif print -r -- $TONE_LOG | grep -q "LoudnessMeter init"; then
        result PASS "10 after six refused rates the meter came within the 10 s of tone"
    else
        result FAIL "10 after six refused rates no meter within 10 s"
    fi
}

# 12. Five builds fail (the panel shows on the fourth), the sixth reads no
# default output.
case_12() {
    local since=$(mark)
    open --env LUFSBAR_FAIL_START_AT=tap --env LUFSBAR_FAIL_START_ATTEMPTS=1,2,3,4,5 --env LUFSBAR_NO_OUTPUT_AT_ATTEMPT=6 "$APP"
    if ! applog_wait "$since" 35 "reading no default output on purpose"; then
        quit_app; cannot "12: never reached the moment with no default output (switch missing in this build?)"; return
    fi
    sleep 1
    local logtext=$(applog_since "$since")
    quit_app
    local panel=$(panels $logtext)
    local cleared=$(print -r -- $logtext | grep -c "the system audio access error is cleared")
    if (( panel == 0 )); then
        cannot "12: the panel never showed"
    elif (( cleared >= 1 )); then
        result PASS "12 with no default output the panel went away"
    else
        result FAIL "12 with no default output the panel stayed up (nothing is failing)"
    fi
}

case_1
fail_once_case 2 uid "UID read"
case_3
# 4: any real rate (the device's own), not 5.
meter_case 4 "the rate read as 5 Hz once" "[0-9][0-9][0-9][0-9][0-9]*" 5 --env LUFSBAR_METER_RATE=5 --env LUFSBAR_METER_RATE_TIMES=1
meter_case 5 "a device at 1,536,000 Hz" 1536000 1536000 --env LUFSBAR_METER_RATE=1536000
# 6. Attempts 1-3 and 5 fail; the fourth starts with nothing playing.
episode_case 6 "capture started" "after three failures and a start" \
    --env LUFSBAR_FAIL_START_AT=tap --env LUFSBAR_FAIL_START_ATTEMPTS=1,2,3,5
case_7
case_8
fail_once_case 9 defaultdevice "read of the default output"
case_10
# 11. Attempts 1-3 fail, the fourth build reads no default output, and the
# next (on B, the fourth to reach the tap) fails.
episode_case 11 "reading no default output on purpose" "after three failures and no output" \
    --env LUFSBAR_FAIL_START_AT=tap --env LUFSBAR_FAIL_START_ATTEMPTS=1,2,3,4 --env LUFSBAR_NO_OUTPUT_AT_ATTEMPT=4
case_12

(( FAILED )) && exit 1
(( CANNOT )) && exit 2
exit 0
