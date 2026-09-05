import os
import sys

import importlib.util
spec = importlib.util.spec_from_file_location(
    "shim", os.path.join(os.path.dirname(os.path.abspath(__file__)), "socat-telnet-shim.py"))
shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shim)

F = shim.TelnetFilter
fails = 0


def eq(got, want, label):
    global fails
    if got == want:
        print("  PASS: %s" % label)
    else:
        fails += 1
        print("  FAIL: %s\n        got  %r\n        want %r" % (label, got, want))


f = F()
eq(f.feed(b"root"), (b"root", b""), "plain data passes through")

f = F()
eq(f.feed(b"\xff\xfd\x01"), (b"", b""), "DO ECHO stripped, no reply (announced)")

f = F()
eq(f.feed(b"\xff\xfd\x03"), (b"", b""), "DO SGA stripped, no reply (announced)")

f = F()
eq(f.feed(b"\xff\xfd\x18"), (b"", b"\xff\xfc\x18"), "DO TTYPE -> WONT TTYPE")

f = F()
eq(f.feed(b"\xff\xfb\x18"), (b"", b"\xff\xfe\x18"), "WILL TTYPE -> DONT TTYPE")

f = F()
eq(f.feed(b"\xff\xfc\x18"), (b"", b""), "WONT never answered (no loop)")

f = F()
eq(f.feed(b"\xff\xfe\x18"), (b"", b""), "DONT never answered (no loop)")

f = F()
eq(f.feed(b"a\xff\xffb"), (b"a\xffb", b""), "IAC IAC -> literal 0xFF")

f = F()
eq(f.feed(b"a\xff\xfa\x18\x00vt100\xff\xf0b"), (b"ab", b""),
   "subnegotiation stripped")

f = F()
eq(f.feed(b"root\r\n"), (b"root\r", b""), "CR LF -> CR")

f = F()
eq(f.feed(b"root\r\x00"), (b"root\r", b""), "CR NUL -> CR")

f = F()
eq(f.feed(b"a\rb"), (b"a\rb", b""), "CR followed by data keeps both")

# state must survive chunk boundaries
f = F()
a = f.feed(b"user\xff")
b = f.feed(b"\xfd\x18")
eq((a[0] + b[0], a[1] + b[1]), (b"user", b"\xff\xfc\x18"),
   "IAC sequence split across reads")

f = F()
a = f.feed(b"pw\r")
b = f.feed(b"\n")
eq((a[0] + b[0], a[1] + b[1]), (b"pw\r", b""), "CR LF split across reads")

f = F()
a = f.feed(b"x\xff\xfa\x18")
b = f.feed(b"\x00vt\xff\xf0y")
eq((a[0] + b[0], a[1] + b[1]), (b"xy", b""), "subnegotiation split across reads")

f = F()
eq(f.feed(b"\xff\xf1"), (b"", b""), "2-byte command (NOP) dropped")

eq(shim.escape_iac(b"a\xffb"), b"a\xff\xffb", "device->client escapes 0xFF")
eq(shim.escape_iac(b"plain"), b"plain", "device->client leaves data alone")

print()
print("filter unit tests: %d failed" % fails)
sys.exit(1 if fails else 0)
