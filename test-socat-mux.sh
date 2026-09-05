#! /usr/bin/env bash
# Test suite for socat.sh (many-to-one / one-to-all multiplexer)
# Usage: bash test-socat-mux.sh [path-to-socat.sh]

SCRIPT=${1:-/home/max/claude/socat/socat.sh}
TMP=$(mktemp -d)
PASS=0 FAIL=0

HELPERS=()

# Helpers must be killed by pid and started with stdout redirected: anything
# still holding this script's stdout keeps a piped reader (tail, grep) waiting
# long after the tests are done.
cleanup_all() {
    pkill -f 'lp mux' 2>/dev/null
    local p
    for p in "${HELPERS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    # socat SYSTEM: children (the READY loop) survive their socat parent.
    # $TMP is unique to this run, so these patterns cannot hit anyone else.
    pkill -f "$TMP/device-saw.bin" 2>/dev/null
    pkill -f "PTY,link=$TMP" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup_all EXIT

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected [$2], got [$1])"; fi; }

freeport() {
    local p
    while :; do
        p=$((20000+RANDOM%20000))
        ss -ltn 2>/dev/null | grep -q ":$p\>" || { echo "$p"; return; }
    done
}

echo "== Testing $SCRIPT =="

## --- Test 1: -h prints usage and exits 0 -------------------------------
out=$(timeout 10 bash "$SCRIPT" -h 2>&1); rc=$?
check "$rc" "0" "-h exits 0"
if echo "$out" | grep -q "Usage:"; then ok "-h prints usage"; else bad "-h prints usage (got: $out)"; fi
if echo "$out" | grep -q "command not found"; then bad "-h has no 'command not found'"; else ok "-h has no 'command not found'"; fi

## --- Test 2: missing parameters -> exit 1 + usage ----------------------
out=$(timeout 10 bash "$SCRIPT" 2>&1); rc=$?
check "$rc" "1" "no args exits 1"
if echo "$out" | grep -q "Missing parameter"; then ok "no args reports missing parameter"; else bad "no args reports missing parameter"; fi
if echo "$out" | grep -q "Usage:"; then ok "no args prints usage"; else bad "no args prints usage"; fi

## --- Test 3: unknown option -> exit 1 ----------------------------------
out=$(timeout 10 bash "$SCRIPT" -Z FOO BAR 2>&1); rc=$?
check "$rc" "1" "unknown option exits 1"
if echo "$out" | grep -q "Unknown option"; then ok "unknown option reported"; else bad "unknown option reported"; fi

## --- Test 4: -V shows commands, does not execute them ------------------
P=$(freeport)
out=$(timeout 5 bash "$SCRIPT" -V "TCP4-LISTEN:$P,reuseaddr" EXEC:/bin/cat 2>&1 &
      sleep 3; pkill -f "lp muxlst" 2>/dev/null; wait) 2>/dev/null
if echo "$out" | grep -q "No such file or directory"; then bad "-V does not exec the command string"; else ok "-V does not exec the command string"; fi
if echo "$out" | grep -q "muxfwd"; then ok "-V shows muxfwd command"; else bad "-V shows muxfwd command"; fi
if echo "$out" | grep -q "muxlst"; then ok "-V shows muxlst command"; else bad "-V shows muxlst command"; fi
pkill -f 'lp mux' 2>/dev/null; sleep 0.3

## --- Test 5: script stays alive after starting children ----------------
P=$(freeport)
timeout 20 bash "$SCRIPT" "TCP4-LISTEN:$P,reuseaddr" EXEC:/bin/cat >"$TMP/s5.out" 2>&1 &
SPID=$!
sleep 2
if kill -0 $SPID 2>/dev/null; then ok "script still running after 2s"; else bad "script still running after 2s"; fi
n=$(pgrep -f 'lp mux' 2>/dev/null | wc -l)
check "$n" "2" "both socat children alive"

## --- Test 6: one-to-all fan-out ----------------------------------------
# A and B connect and stay open; C sends "ping"; cat echoes it; all should see it.
socat -T8 "TCP4:127.0.0.1:$P" - >"$TMP/a.out" 2>/dev/null < <(sleep 6) &
socat -T8 "TCP4:127.0.0.1:$P" - >"$TMP/b.out" 2>/dev/null < <(sleep 6) &
sleep 1.5
{ printf 'ping\n'; sleep 3; } | socat -T8 "TCP4:127.0.0.1:$P" - >"$TMP/c.out" 2>/dev/null &
sleep 3

if grep -q ping "$TMP/a.out" 2>/dev/null; then ok "client A received target output"; else bad "client A received target output"; fi
if grep -q ping "$TMP/b.out" 2>/dev/null; then ok "client B received target output"; else bad "client B received target output"; fi
wait 2>/dev/null

## --- Test 7: killing the script leaves no orphan socat processes -------
kill $SPID 2>/dev/null
sleep 2
n=$(pgrep -f 'lp mux' 2>/dev/null | wc -l)
check "$n" "0" "no orphaned socat children after script exits"

## --- Test 8: if one child dies, script exits and reaps the other -------
P=$(freeport)
timeout 20 bash "$SCRIPT" "TCP4-LISTEN:$P,reuseaddr" EXEC:/bin/cat >"$TMP/s8.out" 2>&1 &
SPID=$!
sleep 2
victim=$(pgrep -f 'lp muxlst' | head -1)
if [ -n "$victim" ]; then
    kill "$victim" 2>/dev/null
    sleep 2
    if kill -0 $SPID 2>/dev/null; then bad "script exits when a child dies"; else ok "script exits when a child dies"; fi
    n=$(pgrep -f 'lp mux' 2>/dev/null | wc -l)
    check "$n" "0" "surviving child reaped after sibling death"
else
    bad "could not find muxlst child to kill"
fi
kill $SPID 2>/dev/null
pkill -f 'lp mux' 2>/dev/null

## --- Test 9: --telnet mode ---------------------------------------------
# A raw TCP port leaves a telnet client echoing locally, so every keystroke
# shows twice and a password typed at a non-echoing prompt is visible.
# --telnet must announce IAC WILL ECHO and keep negotiation off the target.
DIR=$(cd "$(dirname "$SCRIPT")" && pwd)
if [ ! -r "$DIR/socat-telnet-shim.py" ]; then
    echo "  SKIP: telnet tests (no socat-telnet-shim.py beside $SCRIPT)"
elif ! type python3 >/dev/null 2>&1 || ! type telnet >/dev/null 2>&1 || ! type script >/dev/null 2>&1; then
    echo "  SKIP: telnet tests (need python3, telnet and script)"
else
    P=$(freeport)
    HOST=$TMP/vhost; DEV=$TMP/vdev
    socat PTY,link="$HOST",raw,echo=0 PTY,link="$DEV",raw,echo=0 >/dev/null 2>&1 &
    HELPERS+=($!)
    sleep 1
    # Simulated device: announces READY once a second, records what it receives.
    socat "$DEV",raw,echo=0 \
          SYSTEM:"(while :; do printf 'READY\\r\\n'; sleep 1; done & cat > $TMP/device-saw.bin)" \
          >/dev/null 2>&1 &
    HELPERS+=($!)
    sleep 0.5

    timeout 30 bash "$SCRIPT" --telnet "TCP4-L:$P,reuseaddr" "file:$HOST,echo=0,raw" \
        >"$TMP/s9.out" 2>&1 &
    SPID=$!
    sleep 2

    n=$(pgrep -f 'lp mux' 2>/dev/null | wc -l)
    check "$n" "3" "--telnet starts three socat processes"

    { sleep 2; printf 'hunter2\n'; sleep 2; printf '\035quit\n'; sleep 1; } \
        | timeout 15 script -q -c "telnet 127.0.0.1 $P" "$TMP/telnet.raw" >/dev/null 2>&1

    if grep -q hunter2 "$TMP/telnet.raw" 2>/dev/null; then
        bad "telnet client does not echo locally"
    else
        ok "telnet client does not echo locally"
    fi
    if grep -q READY "$TMP/telnet.raw" 2>/dev/null; then
        ok "device output reaches the telnet client"
    else
        bad "device output reaches the telnet client"
    fi
    if grep -qa hunter2 "$TMP/device-saw.bin" 2>/dev/null; then
        ok "telnet client input reaches the device"
    else
        bad "telnet client input reaches the device"
    fi
    if LC_ALL=C grep -qa $'\xff' "$TMP/device-saw.bin" 2>/dev/null; then
        bad "no telnet IAC bytes leak to the device"
    else
        ok "no telnet IAC bytes leak to the device"
    fi

    kill $SPID 2>/dev/null
    sleep 2
    n=$(pgrep -f 'lp mux' 2>/dev/null | wc -l)
    check "$n" "0" "--telnet leaves no orphaned processes"
    pkill -f 'lp mux' 2>/dev/null

    ## --- Test 10: --telnet without the shim fails cleanly ---------------
    cp "$SCRIPT" "$TMP/lonely.sh"
    out=$(timeout 10 bash "$TMP/lonely.sh" --telnet "TCP4-L:$(freeport)" EXEC:/bin/cat 2>&1); rc=$?
    check "$rc" "1" "--telnet without the shim exits 1"
    if echo "$out" | grep -q "socat-telnet-shim.py"; then
        ok "--telnet without the shim names the missing file"
    else
        bad "--telnet without the shim names the missing file"
    fi
fi

## --- Test 11: telnet filter unit tests ---------------------------------
if [ -r "$DIR/test-telnet-filter.py" ] && type python3 >/dev/null 2>&1; then
    if out=$(python3 "$DIR/test-telnet-filter.py" 2>&1); then
        ok "telnet filter unit tests ($(echo "$out" | grep -c PASS) assertions)"
    else
        bad "telnet filter unit tests"
        echo "$out" | grep FAIL | sed 's/^/    /'
    fi
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
