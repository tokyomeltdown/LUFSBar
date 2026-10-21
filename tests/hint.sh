#!/bin/zsh
# Checks that the "not detecting any audio yet" hint comes up when the audio is
# going to a device other than the default output.
#
# The default output is set to one device and the tone is played to another for
# 100 seconds. Nothing reaches the device the tap is bound to, so no meter is
# ever built, and the hint (shown after about 90 seconds without audio) has to
# come up anyway. The app logs a line when it decides to show it (read back
# with log show, see applog.sh).
#
# Usage: hint.sh <LUFSBar.app> <tone.wav> "<default device>" "<other device>"
# Needs tone_to_device and default_output (built from this folder) in $BIN.
# Restores the default output and quits the app when it is done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; DEFAULT=$3; OTHER=$4
BIN=${BIN:?set BIN to the folder holding tone_to_device and default_output}
LAUNCHED=$(mark)
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }

finish() {
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
    killall LUFSBar 2>/dev/null
    print "log: /usr/bin/log show --start \"$LAUNCHED\" --predicate 'subsystem == \"$APPLOG_SUBSYSTEM\"' --style compact"
}
trap finish EXIT

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
# On the very first launch the app waits for a click before it taps anything.
if [[ $(defaults read com.tokyomeltdown.lufsbar LUFSBar.hasCompletedFirstLaunchTapStart 2>/dev/null) != 1 ]]; then
    print "start metering once by hand first (first launch waits for a click)"; exit 2
fi
"$BIN/default_output" "$OTHER" >/dev/null || { print "cannot select \"$OTHER\""; exit 2; }
"$BIN/default_output" "$DEFAULT" >/dev/null || { print "cannot select \"$DEFAULT\""; exit 2; }

LAUNCHED=$(mark)
open "$APP"
applog_wait "$LAUNCHED" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }

"$BIN/tone_to_device" "$OTHER" 100 "$TONE" >/dev/null || { print "FAIL  the tone did not play"; exit 1; }

pgrep -x LUFSBar >/dev/null || { print "FAIL  LUFSBar is not running"; exit 1; }
LOGTEXT=$(applog_since "$LAUNCHED")
print -r -- $LOGTEXT | grep -q "LoudnessMeter init" && print "note  a meter was built: something played to $DEFAULT"
if print -r -- $LOGTEXT | grep -q "showing the sound output and access hint"; then
    print "PASS  the hint came up with the audio on $OTHER"
else
    print "FAIL  no hint after 100 s with the audio on $OTHER"; exit 1
fi
