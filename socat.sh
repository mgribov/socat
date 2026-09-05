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

ECHO="echo -e"

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
    $ECHO "\t-d*\tOptions beginning with -d are passed to Socat processes"
    $ECHO "\t-l*\tOptions beginning with -l are passed to Socat processes"
    $ECHO "\t-b|-S|-t|-T|-l <arg>\tThese options are passed to Socat processes"
}

VERBOSE= QUIET= OPTS=
while [ "$1" ]; do
    case "X$1" in
        X-h) usage; exit ;;
        X-V) VERBOSE=1 ;;
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

# We need two free UDP ports (on loopback)
PORT1=$($SOCAT -d -d -T 0.000001 UDP4-RECV:0 /dev/null 2>&1 |grep bound |sed 's/.*:\([1-9][0-9]*\)$/\1/')
PORT2=$($SOCAT -d -d -T 0.000001 UDP4-RECV:0 /dev/null 2>&1 |grep bound |sed 's/.*:\([1-9][0-9]*\)$/\1/')
if [ -z "$PORT1" -o -z "$PORT2" ]; then
    # Probably old Socat version, use a different approach
    if type ss >/dev/null 2>&1; then
        :
    elif type netstat >/dev/null 2>&1; then
        alias ss=netstat
    else
        echo "$0: Failed to determine free UDP ports (old Socat version, no ss, no netstat?)" >&2
        exit 1
    fi
    PORT1= PORT2=
    while [ -z "$PORT1" -o -z "$PORT2" -o "$PORT1" = "$PORT2" ] || ss -aun |grep -e ":$PORT1\>" -e ":$PORT2\>" >/dev/null; do
        PORT1=$((16384+RANDOM))
        PORT2=$((16384+RANDOM))
    done
elif [ "$PORT1" = "$PORT2" ]; then	# seen on etch
    PORT2=$((PORT1+1))
fi
[ "$VERBOSE" ] && echo "# $0: Using UDP ports $PORT1, $PORT2" >&2

IFADDR=127.0.0.1
BCADDR=127.255.255.255

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

# One of the two Socat processes died: report it, take the other one down, and
# exit. Disarm the trap first so that reaping the sibling does not re-enter.
onChildExit() {
    trap - SIGCHLD
    local rc

    if [ -z "$pid1" -a -z "$pid2" ]; then
        return 0
    fi

    if kill -0 "$pid1" 2>/dev/null; then
        wait "$pid2" 2>/dev/null; rc=$?
        [ -z "$QUIET" ] && echo "$0: socat-listener exited with rc=$rc" >&2
        pid2=
        reapChild "$pid1"; pid1=
    else
        wait "$pid1" 2>/dev/null; rc=$?
        [ -z "$QUIET" ] && echo "$0: socat-multiplexer exited with rc=$rc" >&2
        pid1=
        reapChild "$pid2"; pid2=
    fi

    exit 1
}

pid1= pid2=

set -bm

trap 'reapChild "$pid1"; pid1=; reapChild "$pid2"; pid2=' EXIT
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
pid1=$!

if [ "$VERBOSE" ]; then
    $ECHO "$SOCAT -lp muxlst $OPTS \\
        \"$LISTENER\" \\
        \"UDP4-DATAGRAM:$IFADDR:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr\" &"
fi
$SOCAT -lp muxlst $OPTS \
    "$LISTENER" \
    "UDP4-DATAGRAM:$IFADDR:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr" &
pid2=$!

wait
