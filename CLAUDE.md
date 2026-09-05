# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

- `socat.sh` — a locally modified copy of socat's `socat-mux.sh` helper
- `socat-telnet-shim.py` — per-connection telnet front end, used only by `--telnet`
- `test-socat-mux.sh` — regression suite for both
- `test-telnet-filter.py` — unit tests for the shim's IAC state machine

No build system, no README.

**The upstream original is installed at `/usr/bin/socat-mux.sh`** (from the `socat` package). Diff against it before changing anything — it is the reference for everything except the documented local changes below.

Local divergences from upstream, all deliberate:
- `SOCAT` falls back to `$PATH` when there is no `socat` binary beside the script (upstream sets `SOCAT=./socat` unconditionally when `$0` contains a slash, which breaks `bash ./socat.sh`).
- Free-port discovery falls back to `ss`/`netstat` when the socat-based probe yields nothing (old socat versions).
- Teardown goes through `reapChild()` + `onChildExit()` instead of upstream's one-line SIGCHLD trap, and SIGTERM/SIGINT/SIGHUP are trapped.
- `--telnet` adds a third process, the telnet front end.

## Running it

```bash
./socat.sh [-V] [-q] [--telnet] [-d…] [-l…] [-b|-S|-t|-T N] <LISTENER> <TARGET>
# e.g.
./socat.sh TCP4-LISTEN:8080,reuseaddr EXEC:'/bin/cat'
./socat.sh --telnet TCP4-L:2323,reuseaddr file:/dev/ttyUSB0,echo=0,b115200,raw
```

`-V` prints the resolved `socat` path, the chosen ports, and each `socat` command line — the main debugging tool. `-q` suppresses the child-exit messages.

Note the flag is `--telnet`, not `-t`: `-t` is already a pass-through to socat (`-b|-S|-t|-T|-l` all take an argument and are forwarded).

## Testing

```bash
bash test-socat-mux.sh              # 27 assertions, ~40s
bash test-socat-mux.sh /path/to/other-socat.sh
python3 test-telnet-filter.py       # just the IAC state machine, instant
```

Covers the CLI surface (`-h`, missing args, unknown option, `-V`), the one-to-all fan-out with three live clients, teardown (no orphaned `socat` children after the script exits or after one child is killed), and telnet mode driven by a real `telnet` client on a pty via `script`. Telnet tests skip themselves if `python3`, `telnet` or `script` is missing.

Test helpers must be started with stdout redirected and killed by pid on exit. A background helper that inherits the suite's stdout keeps a piped reader (`… | tail`) blocked long after the assertions finish — the suite appears to hang when it has actually completed.

Gotcha when writing tests or ad-hoc checks: the suite finds children with `pgrep -f 'lp mux'`. Any shell command whose *own* argv contains that string matches too, so `pkill -f 'lp mux'` typed directly on a command line can kill the invoking shell. Keep such patterns inside a script file.

No lint config, and `shellcheck` is not installed here.

## Architecture: how the multiplexer works

The script does not proxy anything itself. It starts **two background `socat` processes** joined by a loopback UDP broadcast bus, and the bus is what turns one target into a shared one:

- **`muxlst`** (lines 111-113) — the client side. Binds `LISTENER` (with `,fork` forced on, see below) against `UDP4-DATAGRAM:127.0.0.1:$PORT1,bind=:$PORT2,so-broadcast,so-reuseaddr`. Every forked client handler binds the *same* `$PORT2` via `so-reuseaddr`, so all of them receive each datagram sent to the broadcast address.
- **`muxfwd`** (lines 101-103) — the target side. Binds `TARGET` against `UDP4-DATAGRAM:127.255.255.255:$PORT2,bind=127.0.0.1:$PORT1,so-broadcast`.

So: bytes from *any* client → `$PORT1` → `muxfwd` → merged into the single `TARGET`; bytes from `TARGET` → broadcast to `$PORT2` → fanned out to *every* connected client. The consequences are inherent to the design, not bugs: client input is interleaved with no framing, and every client sees every reply.

`,fork` is force-appended to `LISTENER` (lines 27-30) because the fan-out depends on multiple handler processes sharing `$PORT2`. The regex also appends a second `,fork` when `fork` is followed by further options (`.*,fork,`); socat tolerates the duplicate.

Two free UDP ports are found by running `socat -d -d -T 0.000001 UDP4-RECV:0` and scraping the `bound` line from stderr. If that yields nothing — an older socat — it falls back to random ports in `16384+$RANDOM` checked with the `sockTool` wrapper (`ss`, else `netstat`). That wrapper is a function, not an alias: aliases are not expanded in non-interactive shells unless `expand_aliases` is set, so the original `alias ss=netstat` silently never took effect.

The same trick does **not** work for TCP: `TCP4-LISTEN:0` blocks waiting for a connection instead of printing a bound port and exiting, so the internal port for `--telnet` is chosen with `sockTool -atn` only.

`SOCAT` resolves to a `socat` binary sitting next to the script (`${0%/*}/socat`) before falling back to `$PATH`, so a locally built socat can be tested by dropping it in this directory.

## Telnet mode (`--telnet`)

A raw TCP port is not a telnet server. With nothing sending `IAC WILL ECHO`, a telnet client keeps its own local echo on, so **every keystroke appears twice** (once locally, once echoed by the target) and **a password typed at a non-echoing prompt is shown in clear text**. The mux itself never reflects client input — verified — so this is purely a client-side artifact of the missing negotiation.

`--telnet` inserts a front end and moves the multiplexer's listener behind it:

```
telnet client → muxtel (LISTENER, fork) → EXEC socat-telnet-shim.py
                                            → TCP 127.0.0.1:$PORT3 → muxlst → UDP bus → muxfwd → TARGET
```

One shim process per connection. It announces `IAC WILL ECHO` + `IAC WILL SGA`, then:
- **client → target**: strips IAC sequences and subnegotiations, unescapes `IAC IAC` to a literal `0xFF`, and folds the NVT line ending (`CR LF` / `CR NUL`) down to a bare `CR`, which is what a serial login expects.
- **target → client**: escapes a literal `0xFF` as `IAC IAC`.

It answers `DO`/`WILL` (with `WONT`/`DONT` for anything it did not announce) so clients do not block waiting, and **never answers `DONT`/`WONT`** — replying to a refusal is what creates negotiation loops.

Without `--telnet` nothing about the original two-process path changes.

Connecting without a telnet client needs no front end at all — `socat -,raw,echo=0 TCP:host:2323` puts the local terminal in raw/no-echo mode. Plain `nc` does **not** work as a substitute: it leaves the terminal in canonical mode with `ECHO` on, reproducing the same doubling.

## Process/signal handling

This is where the local work happened and where the bugs were, so change it carefully:

- `set -bm` gives each child its own process group. A terminal signal therefore reaches only the script, never the `socat` children — which is why SIGTERM/SIGINT/SIGHUP are explicitly trapped to `exit 1` and cleanup is left to the EXIT trap. Drop that trap and killing the script orphans both children.
- `onChildExit` (the SIGCHLD handler) disarms itself with `trap - SIGCHLD` before reaping the siblings, otherwise reaping re-enters the handler. It scans `pids[]` with `kill -0` for the one that died, then uses `wait "$pid"` to get its real exit status. (Upstream reports `rc=$?` there, which is the status of its own `kill -0` test, not the child's.)
- Children live in the parallel arrays `pids[]` / `pnames[]` so the same logic covers two processes or three (`--telnet`). Add a child by appending to both.
- `reapChild` must be called **directly**, never as `pid=$(reapChild …)`. It writes to stderr and communicates via exit status, so a command substitution captures the empty string; a `$( )` subshell also cannot clear the caller's pid variable. Clear the pid in the caller instead.
- The script must end in `wait`. Without it execution falls off the end immediately after backgrounding the children, firing the EXIT trap and killing the processes it just started.
