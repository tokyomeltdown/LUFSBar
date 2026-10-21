#!/bin/zsh
# Calibration check for the tap: plays a -18 dBFS tone in five ways and reads
# what the app reports.
#
#   1-3  tone on the default output (afplay follows it)    -> M = -18.0
#   4    default = two-channel device, tone pinned to the  -> nothing measured
#        multichannel one
#   5    default = multichannel device, tone pinned to the -> nothing measured
#        two-channel one
#
# 1.1 corrected the tap by the default output's channel count, so 4 and 5 read
# about 14 dB low and high. Measuring only what goes to the default output means
# a tone sent somewhere else must not show up at all.
#
# "Nothing measured" is also what a dead tap or a crashed app looks like, so
# every such check is followed by one that must read -18.0 on the same tap, and
# the app has to still be running after each check.
#
# Usage: calibration.sh <LUFSBar.app> <tone.wav> "<multichannel device>" "<2ch device>" ["<third device>"]
# Needs tone_to_device and default_output (built from this folder) in $BIN.
# The app is launched with open, so it keeps its own system audio permission,
# and its stderr (where the NSLog lines go) is read from a file.
# Restores the default output and quits the app when it is done.

set -u
APP=$1; TONE=$2; MULTI=$3; STEREO=$4; THIRD=${5:-}
BIN=${BIN:?set BIN to the folder holding tone_to_device and default_output}
WORK=$(mktemp -d)
LOG=$WORK/stderr.log
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }
FAILED=0

finish() {
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
    killall LUFSBar 2>/dev/null
    print "log: $LOG"
}
trap finish EXIT

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
# A misspelt device would otherwise play nothing and pass the "nothing
# measured" checks, so every name is resolved before anything runs.
for device in "$MULTI" "$STEREO" ${THIRD:+"$THIRD"}; do
    "$BIN/default_output" "$device" >/dev/null || { print "cannot select \"$device\""; exit 2; }
done

"$BIN/default_output" "$MULTI" >/dev/null
open --stderr "$LOG" "$APP"
for i in {1..30}; do grep -q "capture started\|failed" "$LOG" 2>/dev/null && break; sleep 1; done
grep -q "capture started" "$LOG" || { print "capture did not start within 30 s"; exit 2; }

# The M= readings logged since line $1, finite ones only.
readings() {
    tail -n +$1 "$LOG" | grep -o "M=-*[0-9.]*" | cut -c3- | grep -E '^-?[0-9]'
}
# The value logged most often: the steady reading, whatever the fade-in and
# fade-out around it did. "none" when nothing finite was logged.
steady() {
    readings $1 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' | grep . || print none
}
# The loudest value logged, for the cases where nothing should be measured.
loudest() {
    readings $1 | sort -g | tail -1 | grep . || print none
}

# Name, default output, how to play, expected ("-18.0" or "none").
check() {
    local name=$1 default=$2 player=$3 want=$4 from got ok played=1
    "$BIN/default_output" "$default" >/dev/null || played=0
    sleep 3
    from=$(( $(wc -l < "$LOG") + 1 ))
    if (( played )); then
        if [[ $player == afplay ]]; then
            # afplay stops at the end of the file however long -t asks for, and
            # the calibration tone is five seconds, so it is played back to back.
            afplay "$TONE" && afplay "$TONE" || played=0
        else
            "$BIN/tone_to_device" "$player" 10 "$TONE" >/dev/null || played=0
        fi
    fi
    if (( ! played )); then
        got="(the tone did not play)"; ok=FAIL
    elif ! pgrep -x LUFSBar >/dev/null; then
        got="(LUFSBar is not running)"; ok=FAIL
    elif [[ $want == none ]]; then
        # Silence on the bound device logs -inf, which readings() leaves out.
        got="$(loudest $from) (loudest)"
        [[ $got == none* ]] || (( ${got%% *} <= -60 )) && ok=PASS || ok=FAIL
    else
        got="$(steady $from) (steady)"
        [[ $got != none* ]] && (( ${got%% *} >= want - 0.2 && ${got%% *} <= want + 0.2 )) && ok=PASS || ok=FAIL
    fi
    [[ $ok == FAIL ]] && FAILED=1
    print "$ok  $name: want $want, got $got"
}

check "1 tone on $MULTI, default $MULTI" "$MULTI" afplay -18.0
check "control: tool to $MULTI, default $MULTI" "$MULTI" "$MULTI" -18.0
check "5 tone pinned to $STEREO, default $MULTI" "$MULTI" "$STEREO" none
check "  still alive: tool to $MULTI, default $MULTI" "$MULTI" "$MULTI" -18.0
check "2 tone on $STEREO, default $STEREO" "$STEREO" afplay -18.0
check "4 tone pinned to $MULTI, default $STEREO" "$STEREO" "$MULTI" none
check "  still alive: tool to $STEREO, default $STEREO" "$STEREO" "$STEREO" -18.0
[[ -n $THIRD ]] && check "3 tone on $THIRD, default $THIRD" "$THIRD" afplay -18.0

exit $FAILED
