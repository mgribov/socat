#! /usr/bin/env bash
# Derived from socat-mux.sh
# Copyright Gerhard Rieger and contributors (see file CHANGES)
# Published under the GNU General Public License V.2, see file COPYING

# Shell script to build a many-to-one, one-to-all communication
# It starts two Socat instances that communicate via IPv4 broadcast,
# the first of which forks a child process for each connected client.

# Local changes vs. upstream socat-mux.sh:
#   - falls back to $PATH when there is no socat binary beside this script
#   - falls back to ss/netstat for free-port discovery on old Socat versions
#   - child processes are torn down via reapChild(), and SIGTERM/SIGINT/SIGHUP
#     are trapped so that clients never outlive the script
#   - --telnet puts a telnet front end in front of the multiplexer

ECHO="echo -e"
SHIMNAME=socat-telnet-shim.py

usage () {
    $ECHO "Usage: $0 <options> <listener> <target>"
    $ECHO "Example:"
    $ECHO "    $0 TCP4-L:1234,reuseaddr,fork TCP:10.2.3.4:12345"
    $ECHO "Clients may connect to port 1234; data sent by any client is forwarded to 10.2.3.4,"
    $ECHO "data provided by 10.2.3.4 is sent to ALL clients"
    $ECHO "    <options>:"
    $ECHO "\t-h\tShow this help text and exit"
    $ECHO "\t-V\tShow Socat commands"
    $ECHO "\t-q\tSuppress most messages"
    $ECHO "\t--telnet\tServe clients as a telnet server: announce IAC WILL ECHO"
    $ECHO "\t\tso telnet clients stop echoing locally, and keep telnet"
    $ECHO "\t\tnegotiation out of the target stream. Needs $SHIMNAME"
    $ECHO "\t\tbeside this script, and python3."
    $ECHO "\t-d*\tOptions beginning with -d are passed to Socat processes"
    $ECHO "\t-l*\tOptions beginning with -l are passed to Socat processes"
    $ECHO "\t-b|-S|-t|-T|-l <arg>\tThese options are passed to Socat processes"
}

VERBOSE= QUIET= OPTS= TELNET=
while [ "$1" ]; do
    case "X$1" in
        X-h) usage; exit ;;
        X-V) VERBOSE=1 ;;
        X--telnet) TELNET=1 ;;
        X-q) QUIET=1; OPTS="-d0" ;;
        X-d*|X-l?*) OPTS="$OPTS $1" ;;
        X-b|X-S|X-t|X-T|X-l) OPT=$1; shift; OPTS="$OPTS $OPT $1" ;;
        X-) break ;;
        X-*) echo "$0: Unknown option \"$1\"" >&2
             usage >&2
             exit 1 ;;
        *) break ;;
    esac
    shift
done

LISTENER="$1"
TARGET="$2"

if [ -z "$LISTENER" -o -z "$TARGET" ]; then
    echo "$0: Missing parameter(s)" >&2
    usage >&2
    exit 1
fi

shopt -s nocasematch
if ! [[ "$LISTENER" =~ .*,fork ]] || [[ "$LISTENER" =~ .*,fork, ]]; then
    LISTENER="$LISTENER,fork"
fi

case "$0" in
    */*) if [ -x ${0%/*}/socat ]; then SOCAT=${0%/*}/socat; fi ;;
esac
if [ -z "$SOCAT" ]; then SOCAT=socat; fi
[ "$VERBOSE" ] && echo "# $0: Using executable $SOCAT" >&2

# ss(8), or netstat(8) where there is no ss. A shell alias is not usable here:
# aliases are not expanded in non-interactive shells without expand_aliases.
if type ss >/dev/null 2>&1; then
    sockTool () { ss "$@"; }
elif type netstat >/dev/null 2>&1; then
    sockTool () { netstat "$@"; }
else
    sockTool () { return 1; }
fi

# We need two free UDP ports (on loopback)
PORT1=$($SOCAT -d -d -T 0.000001 UDP4-RECV:0 /dev/null 2>&1 |grep bound |sed 's/.*:\([1-9][0-9]*\)$/\1/')
PORT2=$($SOCAT -d -d -T 0.000001 UDP4-RECV:0 /dev/null 2>&1 |grep bound |sed 's/.*:\([1-9][0-9]*\)$/\1/')
if [ -z "$PORT1" -o -z "$PORT2" ]; then
    # Probably old Socat version, use a different approach
    if ! type ss >/dev/null 2>&1 && ! type netstat >/dev/null 2>&1; then
        echo "$0: Failed to determine free UDP ports (old Socat version, no ss, no netstat?)" >&2
        exit 1
    fi
    PORT1= PORT2=
    while [ -z "$PORT1" -o -z "$PORT2" -o "$PORT1" = "$PORT2" ] || sockTool -aun |grep -e ":$PORT1\>" -e ":$PORT2\>" >/dev/null; do
        PORT1=$((16384+RANDOM))
        PORT2=$((16384+RANDOM))
    done
elif [ "$PORT1" = "$PORT2" ]; then	# seen on etch
    PORT2=$((PORT1+1))
fi
[ "$VERBOSE" ] && echo "# $0: Using UDP ports $PORT1, $PORT2" >&2

IFADDR=127.0.0.1
BCADDR=127.255.255.255

# --telnet: the listener the user asked for is served by the telnet front end,
# and the multiplexer's own listener moves to a loopback-only port behind it.
LSTADDR="$LISTENER"
if [ "$TELNET" ]; then
    case "$0" in
        */*) SHIM=${0%/*}/$SHIMNAME ;;
        *) SHIM=./$SHIMNAME ;;
    esac
    if [ ! -r "$SHIM" ]; then
        echo "$0: --telnet needs $SHIMNAME beside this script (looked for $SHIM)" >&2
        exit 1
    fi
    case "$SHIM" in
        *\ *) echo "$0: --telnet cannot be used from a path containing spaces: $SHIM" >&2
              exit 1 ;;
    esac
    if ! type python3 >/dev/null 2>&1; then
        echo "$0: --telnet needs python3 in PATH" >&2
        exit 1
    fi

    PORT3=
    n=0
    while [ $n -lt 50 ]; do
        PORT3=$((16384+RANDOM))
        sockTool -atn 2>/dev/null |grep -e ":$PORT3\>" >/dev/null || break
        PORT3= n=$((n+1))
    done
    if [ -z "$PORT3" ]; then
        echo "$0: Failed to determine a free TCP port for the telnet front end" >&2
        exit 1
    fi
    LSTADDR="TCP4-LISTEN:$PORT3,bind=$IFADDR,reuseaddr,fork"
    [ "$VERBOSE" ] && echo "# $0: Using TCP port $PORT3 behind the telnet front end" >&2
fi

# Terminate one child process, given its pid. Tolerates an empty pid (child was
# never started) and a pid that has already exited.
reapChild() {
    local p_childPid=$1

    if [ -z "$p_childPid" ]; then
        return 0
    fi

    if ! [[ "$p_childPid" =~ ^[0-9]+$ ]] || [ "$p_childPid" -le 0 ]; then
        echo "$0: not killing \"$p_childPid\", it is not a positive integer" >&2
        return 1
    fi

    if ! kill -0 "$p_childPid" 2>/dev/null; then
        return 0			# already gone
    fi

    [ "$VERBOSE" ] && echo "# $0: terminating child process $p_childPid" >&2
    kill "$p_childPid" 2>/dev/null
    return 0
}

# Take down every child we started, in reverse order of startup.
reapAll() {
    local i
    for (( i=${#pids[@]}-1; i>=0; i-- )); do
        reapChild "${pids[$i]}"
        pids[$i]=
    done
}

# One of the Socat processes died: report which, take the others down, and
# exit. Disarm the trap first so that reaping the siblings does not re-enter.
onChildExit() {
    trap - SIGCHLD
    local i rc

    for i in "${!pids[@]}"; do
        [ -z "${pids[$i]}" ] && continue
        kill -0 "${pids[$i]}" 2>/dev/null && continue
        wait "${pids[$i]}" 2>/dev/null; rc=$?
        [ -z "$QUIET" ] && echo "$0: ${pnames[$i]} exited with rc=$rc" >&2
        pids[$i]=
    done

    reapAll
    exit 1
}

pids=() pnames=()

set -bm

trap reapAll EXIT
# set -m puts the children in their own process groups, so a terminal signal
# reaches only this script; exit here to let the EXIT trap take them down.
trap 'exit 1' SIGTERM SIGINT SIGHUP
trap onChildExit SIGCHLD

if [ "$VERBOSE" ]; then
    $ECHO "$SOCAT -lp muxfwd $OPTS \\
        \"$TARGET\" \\
        \"UDP4-DATAGRAM:$BCADDR:$PORT2,bind=$IFADDR:$PORT1,so-broadcast\" &"
fi
$SOCAT -lp muxfwd $OPTS \
    "$TARGET" \
    "UDP4-DATAGRAM:$BCADDR:$PORT2,bind=$IFADDR:$PORT1,so-broadcast" &
pids+=($!); pnames+=("socat-multiplexer")

if [ "$VERBOSE" ]; then
    $ECHO "$SOCAT -lp muxlst $OPTS \\
        \"$LSTADDR\" \\
        \"UDP4-DATAGRAM:$IFADDR:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr\" &"
fi
$SOCAT -lp muxlst $OPTS \
    "$LSTADDR" \
    "UDP4-DATAGRAM:$IFADDR:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr" &
pids+=($!); pnames+=("socat-listener")

# The telnet front end must come up last: it relays into the listener above.
if [ "$TELNET" ]; then
    if [ "$VERBOSE" ]; then
        $ECHO "$SOCAT -lp muxtel $OPTS \\
        \"$LISTENER\" \\
        \"EXEC:python3 $SHIM $IFADDR $PORT3\" &"
    fi
    $SOCAT -lp muxtel $OPTS \
        "$LISTENER" \
        "EXEC:python3 $SHIM $IFADDR $PORT3" &
    pids+=($!); pnames+=("telnet-frontend")
fi

wait
