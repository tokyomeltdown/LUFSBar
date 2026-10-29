#!/bin/zsh
# Calibration check for the tap: plays a -18 dBFS tone in several ways and reads
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
#   6-8  the multichannel device's stereo pair (Audio MIDI Setup > Configure
#        Speakers) moved to 3-4: while measuring, after the tap is rebuilt,
#        and back to 1-2                                    -> M = -18.0
#
# macOS plays stereo to the device's stereo pair, so measuring channels 1-2
# regardless reads nothing once the pair is 3-4.
#
# "Nothing measured" is also what a dead tap or a crashed app looks like, so
# every such check is followed by one that must read -18.0 on the same tap, and
# the app has to still be running after each check.
#
# Usage: calibration.sh <LUFSBar.app> <tone.wav> "<multichannel device>" "<2ch device>" ["<third device>"]
# Needs tone_to_device, default_output and stereo_channels (built from this
# folder) in $BIN. The multichannel device needs at least four outputs.
# The app is launched with open, so it keeps its own system audio permission,
# and its log is read back with log show (see applog.sh).
# Restores the default output and the stereo pair, and quits the app, when it
# is done.

set -u
source ${0:A:h}/applog.sh
APP=$1; TONE=$2; MULTI=$3; STEREO=$4; THIRD=${5:-}
BIN=${BIN:?set BIN to the folder holding tone_to_device and default_output}
LAUNCHED=$(mark)
ORIGINAL=$("$BIN/default_output" -u) || { print "no default output to restore afterwards"; exit 2; }
PAIR=$("$BIN/stereo_channels" "$MULTI") && PAIR=${PAIR%% streams=*}
[[ $PAIR == <->' '<-> ]] || { print "cannot read the stereo pair of \"$MULTI\""; exit 2; }
FAILED=0

finish() {
    "$BIN/stereo_channels" "$MULTI" ${=PAIR} >/dev/null || print "could not restore the stereo pair of $MULTI ($PAIR)"
    "$BIN/default_output" "$ORIGINAL" >/dev/null || print "could not restore the default output ($ORIGINAL)"
    killall LUFSBar 2>/dev/null
    print "log: /usr/bin/log show --start \"$LAUNCHED\" --predicate 'subsystem == \"$APPLOG_SUBSYSTEM\"' --style compact"
}

if pgrep -x LUFSBar >/dev/null || pgrep -x "LUFSBar Pro" >/dev/null; then
    print "quit LUFSBar and LUFSBar Pro first"; exit 2
fi
# Only now: on the way out it quits LUFSBar, which above is someone's own copy.
trap finish EXIT
# A misspelt device would otherwise play nothing and pass the "nothing
# measured" checks, so every name is resolved before anything runs.
for device in "$MULTI" "$STEREO" ${THIRD:+"$THIRD"}; do
    "$BIN/default_output" "$device" >/dev/null || { print "cannot select \"$device\""; exit 2; }
done

"$BIN/default_output" "$MULTI" >/dev/null
LAUNCHED=$(mark)
open "$APP"
applog_wait "$LAUNCHED" 30 "capture started" || { print "capture did not start within 30 s"; exit 2; }

# The M= readings logged since mark $1, finite ones only.
readings() {
    applog_since "$1" | grep -o "M=-*[0-9.]*" | cut -c3- | grep -E '^-?[0-9]'
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
    from=$(mark)
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

# Sets the multichannel device's stereo pair, failing the run if it cannot.
pair() {
    "$BIN/stereo_channels" "$MULTI" $1 $2 >/dev/null && return
    print "FAIL  could not set the stereo pair of $MULTI to $1-$2"; FAILED=1
}
check "  on $MULTI with the stereo pair at 1-2" "$MULTI" afplay -18.0
pair 3 4
check "6 stereo pair moved to 3-4 while measuring" "$MULTI" afplay -18.0
check "  away to $STEREO" "$STEREO" afplay -18.0
check "7 back on $MULTI, stereo pair 3-4" "$MULTI" afplay -18.0
pair 1 2
check "8 stereo pair back to 1-2" "$MULTI" afplay -18.0

exit $FAILED
