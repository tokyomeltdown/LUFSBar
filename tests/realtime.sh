#!/bin/zsh
# Checks that the audio thread is left alone, and that a start that fails part
# way takes down what it built.
#
#   1  a meter that is let go of is not freed on the audio thread    (A-17, B5)
#      Launched with LUFSBAR_METER_HOLD_MS=5 and LUFSBAR_DROP_METER_EVERY_MS=300,
#      which drop the meter every 300 ms while the audio thread holds it.
#   2  meters are built on the main thread                           (B5)
#   3  the M= S= I= TP= line comes once a second, from the main thread rather
#      than every few dozen callbacks from the audio thread           (A-04, B5)
#   4  LUFSBAR_FAIL_START_AT = tap | aggregate | ioproc | devicestart: each
#      failure tears down the tap and aggregate it had made           (A-10b, B6)
#   5  a start that fails twice (LUFSBAR_FAIL_START_TIMES=2) is tried again
#      and gets going, without the "system audio access" panel           (B6)
#   6  no test switch is first read on the audio thread (reading one builds
#      the whole environment: allocations and locks)                    (B5)
#
# Usage: realtime.sh <LUFSBar.app> <tone.wav>
# Plays the tone on the current default output. Quits the app when done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
quit_app() {
    killall LUFSBar 2>/dev/null
    for _ in {1..10}; do pgrep -x LUFSBar >/dev/null || return 0; sleep 1; done
}

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
# Only now: on the way out it quits LUFSBar, which above is someone's own copy.
trap quit_app EXIT

# 1-3. Meters dropped while the audio thread holds them, with the tone playing.
LAUNCHED=$(mark)
open --env LUFSBAR_METER_HOLD_MS=5 --env LUFSBAR_DROP_METER_EVERY_MS=300 "$APP"
applog_wait "$LAUNCHED" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }
afplay "$TONE"; afplay "$TONE"; afplay "$TONE"
sleep 2
LOGTEXT=$(applog_since "$LAUNCHED")
quit_app

BUILT=$(print -r -- $LOGTEXT | grep -c "LoudnessMeter init")
OFF_MAIN=$(print -r -- $LOGTEXT | grep -c "a meter was freed off the main thread")
if (( BUILT >= 10 && OFF_MAIN == 0 )); then
    result PASS "1 $BUILT meters built and dropped, none freed on the audio thread"
else
    result FAIL "1 $BUILT meters built, $OFF_MAIN freed on the audio thread (want at least 10 and 0)"
fi

ON_AUDIO=$(print -r -- $LOGTEXT | grep "LoudnessMeter init" | grep -vc "on the main thread")
if (( BUILT > 0 && ON_AUDIO == 0 )); then
    result PASS "2 every meter was built on the main thread"
else
    result FAIL "2 $ON_AUDIO of $BUILT meters were built on the audio thread"
fi

# Seconds between consecutive level lines, as a median.
GAP=$(print -r -- $LOGTEXT | grep " M=" | awk '{ split($2, t, ":"); s = t[1]*3600 + t[2]*60 + t[3];
        if (n++) print s - prev; prev = s }' | sort -g | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)]; else print "none" }')
if [[ $GAP != none ]] && (( GAP >= 0.9 && GAP <= 1.1 )); then
    result PASS "3 the level line comes every ${GAP} s"
else
    result FAIL "3 the level line comes every ${GAP} s (want about 1 s, from the main thread)"
fi

# Meters were asked for dozens of times above, from the audio thread.
OFF_MAIN_SWITCHES=$(print -r -- $LOGTEXT | grep "was read off the main thread" | sed 's/.*test switch //' | sort -u | tr '\n' ' ')
if (( BUILT > 0 )) && [[ -z $OFF_MAIN_SWITCHES ]]; then
    result PASS "6 no test switch was read on the audio thread"
else
    result FAIL "6 test switches read off the main thread: ${OFF_MAIN_SWITCHES:-none, but no meter was built}"
fi

# 4. A start that fails part way.
for point in tap aggregate ioproc devicestart; do
    LAUNCHED=$(mark)
    open --env LUFSBAR_FAIL_START_AT=$point "$APP"
    if ! applog_wait "$LAUNCHED" 30 "start gave up part way"; then
        result FAIL "4 $point: no 'start gave up' within 30 s"
        quit_app; continue
    fi
    LOGTEXT=$(applog_since "$LAUNCHED")
    quit_app
    want=()
    [[ $point != tap ]] && want+=("tap destroyed")
    [[ $point == ioproc || $point == devicestart ]] && want+=("aggregate device destroyed")
    missing=()
    for line in $want; do print -r -- $LOGTEXT | grep -q "$line" || missing+=("$line"); done
    print -r -- $LOGTEXT | grep -q "failing on purpose at $point" || missing+=("failing on purpose at $point")
    if (( ${#missing} == 0 )); then
        result PASS "4 $point: gave up and tore down what it had made"
    else
        result FAIL "4 $point: missing ${(j:, :)missing}"
    fi
done

# 5. The first two attempts fail at the aggregate; the third must go through.
LAUNCHED=$(mark)
open --env LUFSBAR_FAIL_START_AT=aggregate --env LUFSBAR_FAIL_START_TIMES=2 "$APP"
STARTED=no
applog_wait "$LAUNCHED" 15 "capture started" && STARTED=yes
LOGTEXT=$(applog_since "$LAUNCHED")
quit_app
FAILS=$(print -r -- $LOGTEXT | grep -c "failing on purpose at aggregate")
PANEL=$(print -r -- $LOGTEXT | grep -c "showing the system audio access error")
if [[ $STARTED == yes ]] && (( FAILS == 2 && PANEL == 0 )); then
    result PASS "5 two failed starts were tried again and the third went through, with no access panel"
else
    result FAIL "5 failed starts: $FAILS, capture started: $STARTED, access panel shown: $PANEL (want 2, yes, 0)"
fi

exit $FAILED
