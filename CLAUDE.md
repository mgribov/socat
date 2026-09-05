# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `socat.sh` — a locally modified copy of socat's `socat-mux.sh` helper, plus `test-socat-mux.sh`, its regression suite. No build system, no README.

**The upstream original is installed at `/usr/bin/socat-mux.sh`** (from the `socat` package). Diff against it before changing anything — it is the reference for everything except the documented local changes below.

Local divergences from upstream, all deliberate:
- `SOCAT` falls back to `$PATH` when there is no `socat` binary beside the script (upstream sets `SOCAT=./socat` unconditionally when `$0` contains a slash, which breaks `bash ./socat.sh`).
- Free-port discovery falls back to `ss`/`netstat` when the socat-based probe yields nothing (old socat versions).
- Teardown goes through `reapChild()` + `onChildExit()` instead of upstream's one-line SIGCHLD trap, and SIGTERM/SIGINT/SIGHUP are trapped.

## Running it

```bash
./socat.sh [-V] [-q] [-d…] [-l…] [-b|-S|-t|-T N] <LISTENER-ADDRESS> <TARGET-ADDRESS>
# e.g.
./socat.sh TCP4-LISTEN:8080,reuseaddr EXEC:'/bin/cat'
```

`-V` prints the resolved `socat` path, the chosen UDP ports, and the two `socat` command lines — the main debugging tool. `-q` suppresses the child-exit messages.

## Testing

```bash
bash test-socat-mux.sh              # 18 assertions, ~25s
bash test-socat-mux.sh /path/to/other-socat.sh
```

Covers the CLI surface (`-h`, missing args, unknown option, `-V`), the one-to-all fan-out with three live clients, and teardown (no orphaned `socat` children after the script exits or after one child is killed).

Gotcha when writing tests or ad-hoc checks: the suite finds children with `pgrep -f 'lp mux'`. Any shell command whose *own* argv contains that string matches too, so `pkill -f 'lp mux'` typed directly on a command line can kill the invoking shell. Keep such patterns inside a script file.

No lint config, and `shellcheck` is not installed here.

## Architecture: how the multiplexer works

The script does not proxy anything itself. It starts **two background `socat` processes** joined by a loopback UDP broadcast bus, and the bus is what turns one target into a shared one:

- **`muxlst`** (lines 111-113) — the client side. Binds `LISTENER` (with `,fork` forced on, see below) against `UDP4-DATAGRAM:127.0.0.1:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr`. Every forked client handler binds the *same* `$PORT2` via `so-reuseaddr`, so all of them receive each datagram sent to the broadcast address.
- **`muxfwd`** (lines 101-103) — the target side. Binds `TARGET` against `UDP4-DATAGRAM:127.255.255.255:$PORT2,bind=127.0.0.1:$PORT1,so-broadcast`.

So: bytes from *any* client → `$PORT1` → `muxfwd` → merged into the single `TARGET`; bytes from `TARGET` → broadcast to `$PORT2` → fanned out to *every* connected client. The consequences are inherent to the design, not bugs: client input is interleaved with no framing, and every client sees every reply.

`,fork` is force-appended to `LISTENER` (lines 27-30) because the fan-out depends on multiple handler processes sharing `$PORT2`. The regex also appends a second `,fork` when `fork` is followed by further options (`.*,fork,`); socat tolerates the duplicate.

Two free UDP ports are found by running `socat -d -d -T 0.000001 UDP4-RECV:0` and scraping the `bound` line from stderr (lines 39-40). If that yields nothing — an older socat — it falls back to random ports in `16384+$RANDOM` checked against `ss -aun` (or `netstat` aliased to `ss`).

`SOCAT` resolves to a `socat` binary sitting next to the script (`${0%/*}/socat`) before falling back to `$PATH`, so a locally built socat can be tested by dropping it in this directory.

## Process/signal handling

This is where the local work happened and where the bugs were, so change it carefully:

- `set -bm` gives each child its own process group. A terminal signal therefore reaches only the script, never the `socat` children — which is why SIGTERM/SIGINT/SIGHUP are explicitly trapped to `exit 1` and cleanup is left to the EXIT trap. Drop that trap and killing the script orphans both children.
- `onChildExit` (the SIGCHLD handler) disarms itself with `trap - SIGCHLD` before reaping the sibling, otherwise reaping re-enters the handler. It identifies the dead child by testing `kill -0 "$pid1"`, then uses `wait "$pid"` to get the real exit status. (Upstream reports `rc=$?` there, which is the status of its own `kill -0` test, not the child's.)
- `reapChild` must be called **directly**, never as `pid=$(reapChild …)`. It writes to stderr and communicates via exit status, so a command substitution captures the empty string; a `$( )` subshell also cannot clear the caller's pid variable. Clear the pid in the caller instead (`reapChild "$pid1"; pid1=`).
- The script must end in `wait`. Without it execution falls off the end immediately after backgrounding both processes, firing the EXIT trap and killing the children it just started.
