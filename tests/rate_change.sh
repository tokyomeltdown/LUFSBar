#!/bin/zsh
# Checks that the meter follows a change of sample rate on the device it is
# bound to (B4). The device stays the same object, so nothing about the
# default output changes; 1.1.1 before this fix kept measuring 96 kHz audio
# with a meter built for 48 kHz and read M -18.7, TP -17.2 for a -18.0 tone.
#
#   1  the tone at the device's starting rate                     -> M and TP -18.0
#   2  the device switched to <other rate> while the tone plays    -> M and TP -18.0,
#      and a meter rebuilt at that rate
#   3  and back to the starting rate                              -> the same
#   4  switched to <other rate> while the right-click menu is open -> M -18.0
#      while the menu is still open (the main dispatch queue is not served
#      under a menu, so a rebuild queued there waited for it to close)
#
# The switch itself is a real transient: the player restarts its output at
# the new rate, and true peak holds what it played (-16.9 dBTP measured with a
# correct 96 kHz meter, against -18.0 when the device starts at 96 kHz). So
# after each switch the tone stops for 3 s, which the app's 2 s silence reset
# uses to clear the figures; the first tone started after the change peaks
# high at its start as well, so it is played once and let go of the same way,
# and the steady tone is measured after that. A meter still built for the old
# rate reads M -18.7 there.
#
# Usage: rate_change.sh <LUFSBar.app> <tone.wav> "<device>" <other rate>
# The device must be the default output. Needs sample_rate (built from this
# folder) in $BIN. Restores the device's rate and quits the app when done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; DEVICE=$3; OTHER=$4
BIN=${BIN:?set BIN to the folder holding sample_rate}
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
START_RATE=$("$BIN/sample_rate" "$DEVICE") || { print "cannot read the rate of \"$DEVICE\""; exit 2; }
# The afplay processes this test started, and only those.
stop_tone() {
    [[ -n ${TONE_PID:-} ]] || return 0
    pkill -P $TONE_PID afplay 2>/dev/null
    kill $TONE_PID 2>/dev/null
    TONE_PID=
}
finish() {
    stop_tone
    killall LUFSBar 2>/dev/null
    "$BIN/sample_rate" "$DEVICE" $START_RATE >/dev/null || print "could not put \"$DEVICE\" back to $START_RATE"
}
trap finish EXIT

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi

# The figures of the last few level lines since a mark: the most common M and TP.
steady() {
    local lines=$(applog_since "$1" | grep " M=" | tail -4)
    local m=$(print -r -- $lines | grep -o " M=-*[0-9.]*" | cut -c4- | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    local tp=$(print -r -- $lines | grep -o " TP=-*[0-9.]*" | cut -c5- | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    print "${m:-none} ${tp:-none}"
}
# Name, mark the reading is taken from, mark the rebuild is looked for from,
# and the rate a meter must have been built at since then (or "").
check() {
    local name=$1 since=$2 rebuilt_since=$3 rate=$4 m tp built=yes
    read m tp <<< "$(steady $since)"
    [[ -n $rate ]] && ! applog_since "$rebuilt_since" | grep -q "LoudnessMeter init sampleRate=$rate " && built=no
    if ! pgrep -x LUFSBar >/dev/null; then
        result FAIL "$name: LUFSBar is not running"
    elif [[ $m != none && $tp != none && $built == yes ]] && (( m >= -18.2 && m <= -17.8 && tp >= -18.2 && tp <= -17.8 )); then
        result PASS "$name: M $m, TP $tp${rate:+, meter rebuilt at $rate Hz}"
    else
        result FAIL "$name: M $m, TP $tp (want -18.0 for both)${rate:+, meter rebuilt at $rate Hz: $built}"
    fi
}
# afplay can fail to start while the device is still settling after a rate
# change ("AudioQueueStart failed"), so a failed play is tried again.
play_once() {
    for _ in 1 2 3; do afplay "$TONE" 2>/dev/null && return 0; sleep 1; done
    print "note  afplay did not start"
    return 1
}
tone() { play_once; play_once }
# Switches while the tone plays, lets it end, waits out the silence reset,
# then plays the tone again and measures it.
switch_and_measure() {
    local name=$1 rate=$2 switched measure
    tone & TONE_PID=$!
    sleep 3
    switched=$(mark)
    "$BIN/sample_rate" "$DEVICE" $rate >/dev/null || { result FAIL "$name: could not set \"$DEVICE\" to $rate"; return }
    wait $TONE_PID; TONE_PID=
    # The first tone started after a rate change also peaks above -18 dBTP at
    # its start (seen with the meter before and after the fix alike), so one is
    # played and let go of before the one that is measured.
    sleep 3
    play_once
    sleep 3
    measure=$(mark)
    tone
    check "$name" "$measure" "$switched" $rate
}

LAUNCHED=$(mark)
open "$APP"
applog_wait "$LAUNCHED" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }
tone
check "1 at $START_RATE Hz" "$LAUNCHED" "$LAUNCHED" ""
switch_and_measure "2 switched to $OTHER Hz while playing" $OTHER
switch_and_measure "3 back to $START_RATE Hz while playing" $START_RATE

# 4. Relaunched with the right-click menu opening 3 s in (it closes itself 8 s
# later); the rate changes 1 s after it opens. Momentary is read from the
# lines between 4 s after the change and the menu closing; the true peak is
# left out, since the switch's own transient is in that window.
killall LUFSBar 2>/dev/null; sleep 2
LAUNCHED=$(mark)
open --env LUFSBAR_OPEN_MENU_AFTER_SECONDS=3 "$APP"
applog_wait "$LAUNCHED" 30 "capture started" || { result FAIL "4 capture did not start"; exit 1; }
{ for _ in 1 2 3; do afplay "$TONE"; done } & TONE_PID=$!
applog_wait "$LAUNCHED" 15 "right-click menu opened" || result FAIL "4 the menu did not open"
sleep 1
"$BIN/sample_rate" "$DEVICE" $OTHER >/dev/null || result FAIL "4 could not set \"$DEVICE\" to $OTHER"
sleep 4; READ_FROM=$(mark)
applog_wait "$LAUNCHED" 15 "right-click menu closed"
LOG4=$(applog_since "$READ_FROM")
CLOSED=$(print -r -- $LOG4 | grep "right-click menu closed" | head -1 | awk '{print $2}')
M4=$(print -r -- $LOG4 | grep " M=" | awk -v b="$CLOSED" '$2 < b' | grep -o " M=-*[0-9.]*" | cut -c4- | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
stop_tone
if [[ -n $M4 ]] && (( M4 >= -18.2 && M4 <= -17.8 )); then
    result PASS "4 switched to $OTHER Hz under the right-click menu: M $M4 before it closed"
else
    result FAIL "4 switched to $OTHER Hz under the right-click menu: M ${M4:-none} before it closed (want -18.0)"
fi

exit $FAILED
