# Sourced by the app tests. LUFSBar logs through os.Logger, so its lines are
# read back with log show, asked for a window that starts at a mark. (log
# stream into a file has been seen to drop lines written on the audio thread;
# log show for the same moment had them all.)

APPLOG_SUBSYSTEM=com.tokyomeltdown.lufsbar

# The current time in the form log show --start takes. Whole seconds, so a
# window can include up to a second from before the mark.
mark() { date '+%Y-%m-%d %H:%M:%S' }

# The app's log lines since a mark.
applog_since() {
    /usr/bin/log show --start "$1" --predicate "subsystem == \"$APPLOG_SUBSYSTEM\"" --style compact 2>/dev/null \
        | grep -F "[$APPLOG_SUBSYSTEM"
}

# Waits up to $2 seconds (default 30) for a line matching $3 after mark $1.
# Each look takes a moment, so this is checked about every two seconds.
applog_wait() {
    local since=$1 seconds=${2:-30} pattern=$3 waited=0
    while (( waited < seconds )); do
        applog_since "$since" | grep -q -- "$pattern" && return 0
        sleep 2; (( waited += 2 ))
    done
    return 1
}
