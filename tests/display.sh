#!/bin/zsh
# Checks what the app shows, read from its once-a-second level line (which
# carries the menu bar text, the popover's four figures and the metric) and,
# for Settings, through the accessibility API.
#
#   1  callbacks stop: the menu bar and the popover go to "--"       (N2, D-05)
#   2  the menu bar metric chosen in the right-click menu is kept     (B9)
#      across a relaunch
#   3  the meter keeps going while the right-click menu is open       (B10)
#   4  in steady silence, the views are not told to redraw            (M2)
#   5  a Launch at Login change that fails puts the toggle back       (B8)
#
# The menu bar item may be hidden (behind the notch, or turned off in System
# Settings > Menu Bar), so the menu and Settings are opened by test switches
# rather than by clicking it.
#
# Usage: display.sh <LUFSBar.app> <tone.wav>
# Needs axui (built from this folder) in $BIN, and the Accessibility
# permission for whatever runs it. Plays the tone on the default output.
# Restores the menu bar metric setting and quits the app when done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2
BIN=${BIN:?set BIN to the folder holding axui}
DOMAIN=com.tokyomeltdown.lufsbar
SAVED_METRIC=$(defaults read $DOMAIN menuBarMetric 2>/dev/null)
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
quit_app() {
    killall LUFSBar 2>/dev/null
    for _ in {1..10}; do pgrep -x LUFSBar >/dev/null || return 0; sleep 1; done
}
finish() {
    quit_app
    if [[ -n $SAVED_METRIC ]]; then defaults write $DOMAIN menuBarMetric -string $SAVED_METRIC
    else defaults delete $DOMAIN menuBarMetric 2>/dev/null; fi
}
trap finish EXIT
launch() {
    local since=$(mark)
    open "$@" "$APP"
    applog_wait "$since" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }
}
level_lines() { applog_since "$1" | grep " M=" }

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
defaults delete $DOMAIN menuBarMetric 2>/dev/null

# 1. The tap stops being fed 6 s after its first callback, with the tone still
# playing (three times five seconds, back to back). Timed from the meter being
# built, since the device can take seconds to start.
SINCE=$(mark)
launch --env LUFSBAR_STALL_AFTER_SECONDS=6
{ afplay "$TONE"; afplay "$TONE"; afplay "$TONE" } & afplay_pid=$!
applog_wait "$SINCE" 15 "LoudnessMeter init"
sleep 3
LIVE=$(level_lines "$SINCE" | tail -1)
sleep 6
STALE=$(level_lines "$SINCE" | tail -1)
wait $afplay_pid
quit_app
# The menu bar text is padded on the left with no-break spaces (U+00A0), not
# ASCII ones, so whatever comes before the figure is skipped.
if [[ $LIVE =~ 'shown="[^"0-9-]*-[0-9]' && $STALE =~ 'shown="[^"0-9-]*--' && $STALE == *'popover=--/--/--/--'* ]]; then
    result PASS "1 after the callbacks stopped, the menu bar and popover show --"
else
    result FAIL "1 while playing: ${LIVE##* M=}; after stopping: ${STALE##* M=}"
fi

# 2. Pick Integrated in the right-click menu, relaunch, and look.
launch --env LUFSBAR_OPEN_MENU_AFTER_SECONDS=2 --env LUFSBAR_MENU_CHOOSE=Integrated
sleep 12
quit_app
STORED=$(defaults read $DOMAIN menuBarMetric 2>/dev/null)
SINCE=$(mark)
launch
sleep 3
METRIC=$(level_lines "$SINCE" | tail -1 | sed -n 's/.*metric=\([a-zA-Z]*\).*/\1/p')
quit_app
if [[ $METRIC == integrated ]]; then
    result PASS "2 Integrated, chosen in the menu, was still chosen after a relaunch"
else
    result FAIL "2 chose Integrated; after a relaunch the menu bar shows $METRIC (stored: ${STORED:-nothing})"
fi
defaults delete $DOMAIN menuBarMetric 2>/dev/null

# 3. The menu opens 3 s after launch and closes itself 8 s later; the tone
# starts once it is open, so the figures have something to change to.
SINCE=$(mark)
launch --env LUFSBAR_OPEN_MENU_AFTER_SECONDS=3
applog_wait "$SINCE" 20 "right-click menu opened" || { result FAIL "3 the menu did not open"; }
afplay "$TONE"
applog_wait "$SINCE" 20 "right-click menu closed"
LOG3=$(applog_since "$SINCE")
quit_app
OPEN=$(print -r -- $LOG3 | grep "right-click menu opened" | head -1 | awk '{print $2}')
CLOSED=$(print -r -- $LOG3 | grep "right-click menu closed" | head -1 | awk '{print $2}')
DURING=$(print -r -- $LOG3 | grep " M=" | awk -v a=$OPEN -v b=$CLOSED '$2 > a && $2 < b')
COUNT=$(print -r -- $DURING | grep -c "M=")
# What the menu bar item itself was showing, not only the model behind it:
# changing titles while the menu is open means the reading kept moving on screen.
NUMBERS=$(print -r -- $DURING | grep -c 'shown="[^"0-9-]*-[0-9]')
TITLES=$(print -r -- $DURING | sed -n 's/.* title="\([^"]*\)".*/\1/p' | sort -u | wc -l | tr -d ' ')
if (( COUNT >= 6 && NUMBERS >= 2 && TITLES >= 3 )); then
    result PASS "3 with the menu open for 8 s: $COUNT level lines, $NUMBERS showing a number, $TITLES different menu bar titles"
else
    result FAIL "3 with the menu open for 8 s: $COUNT level lines (want 6+), $NUMBERS showing a number (want 2+), $TITLES different menu bar titles (want 3+)"
fi

# 4. A few seconds of tone, then silence. The first 10 s window after the tone
# still holds real changes (short-term decaying over its 3 s, the automatic
# reset), so the count is read from a window that is silent throughout.
launch
afplay "$TONE"
QUIET=$(mark); sleep 32
COUNTS=($(applog_since "$QUIET" | sed -n 's/.*published \([0-9]*\) changes.*/\1/p'))
quit_app
STEADY=${COUNTS[-1]:-none}
if (( ${#COUNTS} >= 3 )) && (( STEADY <= 2 )); then
    result PASS "4 in steady silence, $STEADY redraws per 10 s (counts: ${COUNTS})"
else
    result FAIL "4 in steady silence, $STEADY redraws per 10 s (want 2 or fewer; counts: ${COUNTS:-none})"
fi

# 5. Press Launch at Login with the change set to fail.
launch --env LUFSBAR_OPEN_SETTINGS_AFTER_SECONDS=2 --env LUFSBAR_FAIL_LAUNCH_AT_LOGIN=1
sleep 3
P=$(pgrep -x LUFSBar)
BEFORE_VALUE=$($BIN/axui value $P "Launch at Login")
$BIN/axui press $P "Launch at Login" >/dev/null
sleep 2
AFTER_VALUE=$($BIN/axui value $P "Launch at Login")
quit_app
if [[ -n $BEFORE_VALUE && $AFTER_VALUE == $BEFORE_VALUE ]]; then
    result PASS "5 the failed change left the toggle at $AFTER_VALUE, as the system has it"
else
    result FAIL "5 the toggle went from ${BEFORE_VALUE:-?} to ${AFTER_VALUE:-?} although the change failed"
fi

exit $FAILED
