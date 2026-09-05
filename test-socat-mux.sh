#! /usr/bin/env bash
# Test suite for socat.sh (many-to-one / one-to-all multiplexer)
# Usage: bash test-socat-mux.sh [path-to-socat.sh]

SCRIPT=${1:-/home/max/claude/socat/socat.sh}
TMP=$(mktemp -d)
PASS=0 FAIL=0

cleanup_all() {
    pkill -f 'lp muxfwd' 2>/dev/null
    pkill -f 'lp muxlst' 2>/dev/null
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

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
