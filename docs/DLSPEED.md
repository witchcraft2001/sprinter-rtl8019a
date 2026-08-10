# DLSPEED -- UNET HTTP download throughput test

`DLSPEED.EXE` measures sustained TCP receive speed through `UNETRTL.DLL`.
It downloads and discards a plain HTTP response, so the test size is limited
by the server and the 32-bit `Content-Length`, not by Sprinter RAM.

## Usage

```
DLSPEED.EXE http://host[:port]/path
DLSPEED.EXE /?
```

The utility loads `UNETRTL.DLL` from the current directory. Configure and
bring up the network first:

```
NETCFG -i
IFUP
```

Only `http://` is supported. The response must be HTTP/1.x status 2xx with a
non-zero `Content-Length`. Redirects, HTTPS, chunked transfer encoding and
compressed content are rejected because they would make the byte count
ambiguous.

## Deterministic host test

On the host computer, run:

```
python3 tools/dev/dlspeed_server.py --bind 192.168.1.36 --port 8080 --count 4194304
```

On Sprinter, use the address printed by the server:

```
DLSPEED http://192.168.1.36:8080/test.bin
```

The default payload is 4 MiB. The DSS real-time clock has one-second
resolution, so a 512 KiB sample taking only 4--6 seconds still has a large
quantization error. DLSPEED waits for a second
edge, sends the GET immediately, remains silent during transfer, and stops at
the exact advertised body length. A transfer completed within the same
reported RTC second is rejected as too short.

Successful output includes the exact byte count, elapsed seconds, B/s or
KB/s, `Integrity: OK`, and `RESULT OK`.

DLSPEED requests four TCP MSS blocks (2144 bytes) per public `RECV`. This is
intentional: it verifies that UNETRTL ends the call with a cumulative ACK
after three segments and leaves the fourth segment for the next call.

## DLL versus direct A/B test

The developer image also contains two controls. `DLDIRECT.EXE` links the
stack directly and parses from the driver's RX buffer. `DLDIRCP.EXE` is the
same direct build but first copies every payload byte to a caller-style
buffer. Both use the same reliable TCP, request/parser and saved STOP.

Run both against the same 4 MiB server, preferably alternating their order:

```
DLSPEED  http://192.168.1.36:8080/test.bin
DLDIRECT http://192.168.1.36:8080/test.bin
DLDIRCP  http://192.168.1.36:8080/test.bin
DLSPEED  http://192.168.1.36:8080/test.bin
```

Repeat until each utility has five successful samples. Compare median KiB/s:

- `DLDIRECT - DLDIRCP` estimates the memory-copy cost.
- `DLDIRCP - DLSPEED` estimates DLL dispatch, page mapping and ABI adapter.
- `DLDIRECT - DLSPEED` is the complete public DLL-path cost.

This does not compare the RTL stack with ESP-AT.

## Exit status

- `0` -- complete body received and measured.
- `1` -- invalid command line.
- `2` -- DLL or RTL8019AS hardware could not be loaded/started.
- `3` -- TCP, HTTP, receive, RTC, cancellation, or short-sample error.
- `4` -- network environment is not configured.

DLSPEED is a developer diagnostic. It is included in the test floppy image
but omitted from the release ZIP.
