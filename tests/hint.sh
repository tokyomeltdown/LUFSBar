#!/bin/zsh
# Checks that the "not detecting any audio yet" hint comes up when the audio is
# going to a device other than the default output.
#
#   1  the tone plays to another device for 100 s, nothing to the default
#   2  the same, while something keeps a near-silent stream (-100 dBFS) open
#      on the default output, as a browser tab can: that is not audio either
#      (below the -70 LUFS absolute gate of BS.1770), so the hint still comes
#
# Nothing audible reaches the device the tap is bound to, so the hint (shown
# after about 90 seconds without audio) has to come up. The app logs a line
# when it decides to show it (read back with log show, see applog.sh). If
# something else audible played to the default output meanwhile, the hint
# rightly stays away, and the case reports "cannot test" (exit 2).
#
# Usage: hint.sh <LUFSBar.app> <tone.wav> "<default device>" "<other device>"
# Needs tone_to_device, default_output and make_tone (built from this folder)
# in $BIN. Restores the default output and quits the app when it is done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; DEFAULT=$3; OTHER=$4
BIN=${BIN:?set BIN to the folder holding tone_to_device, default_output and make_tone}
for tool in tone_to_device default_output make_tone; do
    [[ -x $BIN/$tool ]] || { print "no $tool in $BIN: build it from tests/$tool.swift"; exit 2; }
done
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
# On the very first launch the app waits for a click before it taps anything.
if [[ $(defaults read com.tokyomeltdown.lufsbar LUFSBar.hasCompletedFirstLaunchTapStart 2>/dev/null) != 1 ]]; then
    print "start metering once by hand first (first launch waits for a click)"; exit 2
fi
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }
WORK=$(mktemp -d)
finish() {
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
    killall LUFSBar 2>/dev/null
    rm -rf $WORK
}
# Only now: on the way out it quits LUFSBar, which above is someone's own copy.
trap finish EXIT
"$BIN/default_output" "$OTHER" >/dev/null || { print "cannot select \"$OTHER\""; exit 2; }
"$BIN/default_output" "$DEFAULT" >/dev/null || { print "cannot select \"$DEFAULT\""; exit 2; }
"$BIN/make_tone" -100 5 48000 $WORK/quiet.wav || { print "could not make the quiet tone"; exit 2; }

quit_app() {
    killall LUFSBar 2>/dev/null
    for _ in {1..10}; do pgrep -x LUFSBar >/dev/null || return 0; sleep 1; done
}
# The loudest Momentary the level lines show, or "none" when none had a figure.
loudest() {
    print -r -- $1 | grep " M=" | sed -n 's/.* M=\(-\{0,1\}[0-9][0-9.]*\) .*/\1/p' | sort -g | tail -1 | grep . || print none
}

# Runs one case: $1 the case number, $2 what plays to the default output
# alongside the tone on the other device ("" for nothing).
run_case() {
    local n=$1 quiet=$2
    local since=$(mark)
    open "$APP"
    applog_wait "$since" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }
    local quiet_pid=
    if [[ -n $quiet ]]; then
        "$BIN/tone_to_device" "$DEFAULT" 100 $quiet >/dev/null & quiet_pid=$!
    fi
    "$BIN/tone_to_device" "$OTHER" 100 "$TONE" >/dev/null || { result FAIL "$n the tone did not play"; quit_app; return; }
    [[ -n $quiet_pid ]] && wait $quiet_pid
    pgrep -x LUFSBar >/dev/null || { result FAIL "$n LUFSBar is not running"; return; }
    local logtext=$(applog_since "$since")
    quit_app
    local top=$(loudest $logtext)
    if [[ $top != none ]] && (( top >= -70 )); then
        print "cannot test $n: something audible played to $DEFAULT (Momentary up to $top), run it again"; exit 2
    fi
    if [[ -n $quiet && $top == none ]]; then
        print "cannot test $n: the near-silent stream never reached the meter"; exit 2
    fi
    if print -r -- $logtext | grep -q "showing the sound output and access hint"; then
        result PASS "$n the hint came up with the audio on $OTHER${quiet:+ and a near-silent stream on $DEFAULT (M up to $top)}"
    else
        result FAIL "$n no hint after 100 s with the audio on $OTHER${quiet:+ and a near-silent stream on $DEFAULT (M up to $top)}"
    fi
}

run_case 1 ""
run_case 2 $WORK/quiet.wav
exit $FAILED
