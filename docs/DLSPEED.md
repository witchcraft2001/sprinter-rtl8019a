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

DLSPEED offers 2144 caller bytes per public `RECV`. Together with UNETRTL's
536-byte durable queue this reaches the 2680-byte active-window cap. Version
0.3.7 keeps the DLL receive MSS at 536: the caller buffer is exactly four
segments and the durable queue is a fifth segment. This avoids the stop/start
receive-window cycle measured with DLL MSS 1460 in 0.3.6. Direct clients still
advertise MSS 1460. Outbound SEND chunks remain 536 bytes. Arbitrary positive
caller sizes are valid; a segment
crossing the caller boundary is acknowledged only after its fitting prefix and
up to 536 bytes of tail are saved. The caller's original timeout is used only
while waiting for the first byte; further reads use a bounded two-tick wait.

## DLL versus direct A/B test

The developer image also contains two controls. `DLDIRECT.EXE` links the
stack directly and parses from the driver's RX buffer. `DLDIRCP.EXE` is the
same direct build but first copies every payload byte to a caller-style
buffer. Both use the same reliable TCP, request/parser and saved STOP.

Run all controls against the exact same URL and server process, preferably
alternating their order. Changing between `192.168.1.36:8080` and
`192.168.7.1:18081` also changes the host interface/path and is not an EXE A/B.

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

## Experimental receive-window A/B test

`DLWIN3.EXE` is a developer-image-only DLDIRECT variant. It advertises a
4380-byte receive window (three MSS) instead of 2920 (two MSS). Its banner
includes `EXPERIMENT RXWIN=4380`; MSS remains 1460 and the ACK policy,
HTTP parser, timing and discard-without-disk-I/O path are unchanged.
The regular DLDIRECT, DLDIRCP, WGET, FTP and UNETRTL builds are unaffected.

```
DLDIRECT http://modland.antarctica.no/allmods.zip
DLWIN3   http://modland.antarctica.no/allmods.zip
DLDIRECT http://modland.antarctica.no/allmods.zip
```

Keep the URL, route and emulator speed unchanged. Capture each run separately
on feth1, starting before the SYN, and compare throughput AND retransmissions.
Verify window 4380 and MSS 1460 in the experimental SYN and window 4380 in
its ACKs. Require the same received byte count, `Integrity: OK` and `RESULT OK`.
The existing integrity message checks HTTP framing/length, not a file hash.

This is not an approved production window increase. Three full packets leave
less NIC ring headroom; earlier file-client tests saw overflows with this
window. Stop testing on a timeout/failure and retain the capture and screen.
Do not apply the experiment to FTP/WGET or the DLL without separate validation.
MAME and real-hardware acceptance remain pending. Exit codes match DLDIRECT:
0 success, 1 usage, 2 missing NIC, 3 network/HTTP/RTC/cancel error,
4 missing network environment.

## DLOOO3 loss-recovery experiment

`DLOOO3.EXE` keeps DLWIN3's MSS 1460 and 4380-byte advertised window, but
adds two private 1460-byte slots for segments that arrive ahead of `RCV.NXT`.
It is on the developer floppy only and is excluded from the release ZIP.
The banner is `DLOOO3 ... RXWIN=4380 OOO=2`.

When a segment fills a hole, DLOOO3 emits the current cumulative ACK; it
does not ACK the saved bytes early.  Once the missing segment arrives, the
saved segments are released in sequence before another NIC frame is read.
After the timed transfer it prints decimal `saved`, `delivered`, `nospace`,
`max`, `dup`, `overlap`, `badlen`, `oowin`, `badframe`, and `ackfail`
counters, followed by the driver's `ovw` and `txfail` counters. Event
counters are saturating 16-bit values; `max`, `ovw`, and `txfail` are
saturating bytes. Do not compare those lines during the timed part -- the
program deliberately prints nothing while downloading.

`DLTUNE.EXE` adds runtime `-w 3|6|9` and `-a 1|2` choices to the same
two-slot experiment. The SYN starts at 4380 bytes in every mode; the receive
edge can then grow by 2920 bytes per ACK of new sequential data, up to the
selected maximum. Wider windows do not add OOO slots, so `nospace` and NIC
`ovw` may increase under load. A larger selected maximum is an experiment,
not a promise of higher throughput.

For MAME acceptance, run DLWIN3 and DLOOO3 three times each, alternating
the two programs against the same URL and taking one `feth1` capture per
run. Check byte count, `Integrity: OK`, MSS/window in SYN and normal ACKs,
the duplicate ACK at a simulated/observed hole, and queue use. Compare the
median KiB/s; this experiment does not change WGET, FTP, or UNETRTL.

## Exit status

- `0` -- complete body received and measured.
- `1` -- invalid command line.
- `2` -- DLL or RTL8019AS hardware could not be loaded/started.
- `3` -- TCP, HTTP, receive, RTC, cancellation, or short-sample error.
- `4` -- network environment is not configured.

DLSPEED is a developer diagnostic. It is included in the test floppy image
but omitted from the release ZIP.
