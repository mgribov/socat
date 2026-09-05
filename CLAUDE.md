# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `socat.sh` — a locally modified copy of socat's `socat-mux.sh` helper. It is not a git repo, has no build system, no tests, and no README. The only work here is editing this one script.

The local divergence from upstream is the child-reaping logic (`reapChild`, the `EXIT`/`SIGCHLD` traps, `set -bm`); the argument parsing, port discovery, and the two `socat` invocations are upstream's. Assume any change request is about process/signal handling unless stated otherwise.

## Running it

```bash
bash socat.sh [-V] [-q] [-d…] [-l…] [-b|-S|-t|-T N] <LISTENER-ADDRESS> <TARGET-ADDRESS>
# e.g.
bash socat.sh TCP4-LISTEN:8080,reuseaddr EXEC:'/bin/cat'
```

Invoke with `bash` explicitly: the file has **no shebang** and is not executable, and it uses bashisms (`[[ ]]`, `shopt`, `$RANDOM`, `function`, `set -bm`) despite the `case "X$1"` sh-style idioms.

`-V` prints the resolved `socat` path, the chosen UDP ports, and the two `socat` command lines it is about to run — that is the main debugging tool. There is no lint config; `shellcheck socat.sh` is the useful check.

`socat` is **not installed** in this environment, so the script cannot be run end to end here. `ss` and `netstat` are present, so the fallback port-picking branch (lines 43-55) is exercisable.

## Architecture: how the multiplexer works

The script does not proxy anything itself. It starts **two background `socat` processes** joined by a loopback UDP broadcast bus, and the bus is what turns one target into a shared one:

- **`muxlst`** (lines 111-113) — the client side. Binds `LISTENER` (with `,fork` forced on, see below) against `UDP4-DATAGRAM:127.0.0.1:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr`. Every forked client handler binds the *same* `$PORT2` via `so-reuseaddr`, so all of them receive each datagram sent to the broadcast address.
- **`muxfwd`** (lines 101-103) — the target side. Binds `TARGET` against `UDP4-DATAGRAM:127.255.255.255:$PORT2,bind=127.0.0.1:$PORT1,so-broadcast`.

So: bytes from *any* client → `$PORT1` → `muxfwd` → merged into the single `TARGET`; bytes from `TARGET` → broadcast to `$PORT2` → fanned out to *every* connected client. The consequences are inherent to the design, not bugs: client input is interleaved with no framing, and every client sees every reply.

`,fork` is force-appended to `LISTENER` (lines 27-30) because the fan-out depends on multiple handler processes sharing `$PORT2`. The regex also appends a second `,fork` when `fork` is followed by further options (`.*,fork,`); socat tolerates the duplicate.

Two free UDP ports are found by running `socat -d -d -T 0.000001 UDP4-RECV:0` and scraping the `bound` line from stderr (lines 39-40). If that yields nothing — an older socat — it falls back to random ports in `16384+$RANDOM` checked against `ss -aun` (or `netstat` aliased to `ss`).

`SOCAT` resolves to a `socat` binary sitting next to the script (`${0%/*}/socat`) before falling back to `$PATH`, so a locally built socat can be tested by dropping it in this directory.

## Known-broken state

The script is mid-edit and does not currently work as intended. Do not treat these as pre-existing behavior to preserve:

- **`usage` is never defined.** It is called on `-h`, on an unknown option, and on missing parameters (lines 4, 11, 24) — all three paths print `usage: command not found`. Upstream defines it; it was dropped along with the shebang.
- **`$ECHO` is unset**, so the `-V` command-line dump (lines 97, 107) prints nothing.
- **No `wait` at the end.** The script falls off line 115 immediately after backgrounding both processes, which fires the `EXIT` trap and tears down the very children it just started.
- **`reapChild` is called in a command substitution** (`pid1=$(reapChild "${pid1}")`), but all of its output goes to stderr — so it always assigns the empty string, and the pid is lost rather than updated.
- **Invalid `return` values**: `return -1` (line 73) and `return p_childPid` (line 80) are not valid exit statuses; bash errors on the former and evaluates the latter as an arithmetic expression on an unset name, yielding 0.

When fixing signal handling, note the `SIGCHLD` trap (line 92) disarms itself with `trap - SIGCHLD` after the first child exits, and the commented-out variants above it (lines 90, 94) are the earlier attempts — worth reading before proposing a new approach.
