#! /usr/bin/env python3
"""Minimal telnet server front end for socat.sh --telnet.

socat runs one instance of this per accepted client connection, with the
client on stdin/stdout (EXEC), and we relay to the internal mux listener.

Purpose: a raw TCP port makes a telnet client keep its own local echo on,
so the user sees every keystroke twice (once locally, once echoed by the
serial device) and passwords typed at a non-echoing prompt appear in clear
text.  Announcing IAC WILL ECHO / WILL SGA tells the client to stop echoing
and to send characters as they are typed.

Doing that obliges us to speak enough of RFC 854 to keep negotiation bytes
out of the serial stream:

  client -> device : strip IAC sequences, answer DO/WILL so the client does
                     not block, unescape IAC IAC, and turn the NVT
                     end-of-line (CR LF / CR NUL) into a bare CR
  device -> client : escape a literal 0xFF as IAC IAC
"""

import os
import select
import socket
import sys

IAC  = 255
DONT = 254
DO   = 253
WONT = 252
WILL = 251
SB   = 250
SE   = 240

OPT_ECHO = 1
OPT_SGA  = 3

# Options we announce ourselves; a DO for these needs no reply (we already
# said WILL), which is what keeps negotiation from ping-ponging forever.
ANNOUNCED = (OPT_ECHO, OPT_SGA)

# client->device parser states
S_DATA, S_IAC, S_VERB, S_SB, S_SB_IAC, S_CR = range(6)


class TelnetFilter:
    """Strips telnet negotiation out of the client stream."""

    def __init__(self):
        self.state = S_DATA
        self.verb = None

    def feed(self, data):
        """Return (payload_for_device, bytes_to_send_back_to_client)."""
        out = bytearray()
        reply = bytearray()

        for b in data:
            if self.state == S_CR:
                # NVT: CR LF and CR NUL both mean "end of line" -> bare CR,
                # which is what a serial login prompt expects.
                self.state = S_DATA
                if b in (0, 10):
                    continue
                # a CR followed by anything else: keep the byte
                if b == IAC:
                    self.state = S_IAC
                    continue
                out.append(b)

            elif self.state == S_DATA:
                if b == IAC:
                    self.state = S_IAC
                elif b == 13:
                    out.append(b)
                    self.state = S_CR
                else:
                    out.append(b)

            elif self.state == S_IAC:
                if b == IAC:
                    out.append(IAC)          # escaped literal 0xFF
                    self.state = S_DATA
                elif b in (DO, DONT, WILL, WONT):
                    self.verb = b
                    self.state = S_VERB
                elif b == SB:
                    self.state = S_SB
                else:
                    self.state = S_DATA      # 2-byte command, drop it

            elif self.state == S_VERB:
                # Answer only DO and WILL. Never answer DONT/WONT - replying
                # to a refusal is what creates negotiation loops.
                if self.verb == DO:
                    if b not in ANNOUNCED:
                        reply += bytes([IAC, WONT, b])
                elif self.verb == WILL:
                    reply += bytes([IAC, DONT, b])
                self.state = S_DATA

            elif self.state == S_SB:
                if b == IAC:
                    self.state = S_SB_IAC

            elif self.state == S_SB_IAC:
                # IAC SE ends the subnegotiation; IAC IAC is escaped data
                self.state = S_DATA if b == SE else S_SB

        return bytes(out), bytes(reply)


def escape_iac(data):
    """device -> client: a literal 0xFF must go out as IAC IAC."""
    return data.replace(b"\xff", b"\xff\xff")


def main():
    if len(sys.argv) != 3:
        print("usage: socat-telnet-shim.py <host> <port>", file=sys.stderr)
        return 2

    host, port = sys.argv[1], int(sys.argv[2])
    try:
        up = socket.create_connection((host, port))
    except OSError as e:
        print("telnet-shim: cannot reach mux at %s:%d: %s" % (host, port, e),
              file=sys.stderr)
        return 1

    client_in, client_out = 0, 1
    filt = TelnetFilter()

    # Tell the client: we will echo, and we suppress go-ahead (character mode).
    os.write(client_out, bytes([IAC, WILL, OPT_ECHO, IAC, WILL, OPT_SGA]))

    upfd = up.fileno()
    try:
        while True:
            r, _, _ = select.select([client_in, upfd], [], [])

            if client_in in r:
                data = os.read(client_in, 4096)
                if not data:
                    break
                payload, reply = filt.feed(data)
                if reply:
                    os.write(client_out, reply)
                if payload:
                    up.sendall(payload)

            if upfd in r:
                data = up.recv(4096)
                if not data:
                    break
                os.write(client_out, escape_iac(data))
    except (OSError, BrokenPipeError):
        pass
    finally:
        try:
            up.close()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
