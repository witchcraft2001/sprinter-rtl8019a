# UNETRTL.DLL -- universal network API for the RTL8019AS

`UNETRTL.DLL` is a loadable library (libman 1.3 / L1) that gives any
Sprinter DSS program TCP, UDP, DNS and ping through a small numbered
API, without linking the network stack into the program itself.

The same API is implemented by `UNETESP.DLL` in the Sprinter Wi-Fi
kit.  Function numbers, register conventions and error codes are
identical, so **one consumer binary can drive either card** -- pick
the DLL by name at run time, for example from the `NET` environment
variable (`RTL` or `WIFI`).

The authoritative contract is `src/include/unet.inc` in the source
tree, mirrored byte for byte from the Wi-Fi project; the prose
reference is `docs/UNETAPI.md` there.  This page covers only what is
specific to the RTL backend.

## Prerequisites

The network must already be configured, exactly as for the
stand-alone utilities:

```
NETCFG -i          seed NET_* from NET.CFG (static)
IFUP               bring the link up (static or DHCP)
```

Both publish `NET=RTL` alongside `NET_IP` and `NET_MAC`.  `NETCFG -d`
removes them again.  A configuration made by an older build of the
kit -- `NET_IP` and `NET_MAC` set but no `NET` at all -- is still
accepted.

## Loading

```
    ld   hl,filename      ; "UNETRTL.DLL",0
    ld   a,1              ; window 1 (0x4000) or 2 (0x8000) - NEVER 3
    call l_load           ; -> HL = handle, CF=1 on error
    ...
    ld   hl,(handle)
    ld   b,function       ; UNET_FN_*
    call l_call
    ...
    ld   hl,(handle)
    call l_free
```

`l_load` resolves the file name against the **current directory
only** -- it does not search `PATH` or the program's own directory.
A consumer launched through `PATH` should ask DSS `APPINFO`
(`B = APPINFO_EXE_HOMEDIR`) for its own directory and pass a full
path.

### Window rules

- Load into **window 1 or window 2 only, never window 3 (0xC000)**.
  The RTL8019AS is memory-mapped there during every call, so a DLL
  loaded into window 3 would page itself out.  The DLL detects this
  at load time and refuses.
- All caller buffers must live **below 0xC000 and outside the 16 KB
  window the DLL was loaded into** -- the whole buffer, not just its
  first byte.  Violations return `NERR_PARAM`.
- Host strings are limited to 128 bytes, port strings to 15.
- Keep at least ~256 bytes of free stack across a call.
- The library is not reentrant; make one call at a time.

Arguments and results travel in **A, DE, IX and IY** only; `HL` and
`BC` belong to the libman dispatcher.  **Every function returns its
status in A** -- the dispatcher does not propagate the carry flag, so
test `A`, never `CF`.

## What this backend supports

`GETCAPS` reports `0x001F` = `TCP | UDP | RESOLVE | PING | MULTICHAN`, ABI
`0x0100`.

| Capability | State | Note |
|------------|-------|------|
| `TCP`      | yes   | channels 0 and 1; `SEND` chunks at the 536-byte MSS |
| `UDP`      | yes   | connected UDP, payload up to the standard 1472-byte MTU |
| `RESOLVE`  | yes   | software DNS; never returns `NERR_NOTSUP` |
| `PING`     | yes   | software ICMP echo |
| `MULTICHAN`| yes   | channels 0 and 1 may be open simultaneously |
| `LISTEN`   | no    | client only |
| `RAWETH`   | no    | no raw-frame entry point in the current ABI |
| `RXFLOW`   | no    | the card buffers receive in its own ring |

## Differences from the ESP backend

These are the only places where a portable consumer can observe
which card it got.  None of them changes the calling convention.

- **`RXPAUSE` / `RXRESUME` are no-ops** and always return
  `NERR_OK`, including before `NETINIT`.  The card buffers receive
  in its own ~6.4 KB byte-mode ring, so there is no flow-control state to get
  wrong.  `CAP_RXFLOW` is clear, so a consumer that checks
  capabilities skips them anyway.
- **`SETOPT RXTRIG` returns `NERR_NOTSUP`.**  It selects a 16550
  UART FIFO threshold, and there is no UART here.
  `SETOPT CANCELKEYS` works normally.
- **`NERR_BUSY` means "drain first", not "warming up".**  There is no
  separate network processor here, so the ESP meaning never applies.
  Instead a TCP `SEND` returns `NERR_BUSY` when the channel still
  holds undelivered received data (see "Bounded TCP retransmission"
  below): call `RECV` to drain it, then repeat the `SEND`.  This is
  deliberately distinct from `NERR_PARAM`, which always indicates a
  caller bug (bad channel, buffer out of range) where a retry cannot
  help.
- **`PING` round-trip time is coarse.**  This stack has no
  millisecond timer, so `DE` returns the number of poll-loop ticks
  consumed (roughly milliseconds).  A reply that arrives on the
  first receive pass reports `0`.
- **`GETINFO` fields 8 (SSID) and 9 (BAUD) return an empty string** --
  they are Wi-Fi properties.  Field 12 (hardware descriptor) returns
  `NET_RTL_HW` in the `<slot>/#<base>` form, e.g. `1/#300`.
- **`LASTERR` truncates from the head, not the tail.**  The ESP
  backend returns the tail of the last AT response, because the
  useful `ERROR` line is at the end.  This backend returns a
  fixed-layout diagnostic line instead, so the high-value fields
  come first and a short buffer still shows them:

  ```
  RTL hw=1/#0300 st=CONNECT nerr=04 tcp=02 res=00 tx=E4/42/01/22
      regs=22 42 40 04 02 00 46 60 4A 4B
  ```

  `st` is the operation that failed, `nerr` the status returned,
  `tcp` and `res` the TCP and resolver failure codes, `tx` the
  transmit stage plus ISR/TSR/CR, and `regs` the NIC registers in
  the order `CR ISR DCR RCR TCR IMR PSTART PSTOP BNRY CURR`.  The
  values are captured at the moment of failure, so `LASTERR` never
  reports a chip that has since recovered.

## Bounded TCP retransmission

`UNETRTL.DLL` splits TCP payloads at the 536-byte MSS and sends them
stop-and-wait: each segment must receive its cumulative ACK before the
next segment is sent.  A missing data segment or ACK is retried with the
same TCP sequence number, up to four transmissions with a one-second ACK
wait per attempt.  Exhaustion returns `NERR_SEND`; `DE` still reports the
bytes confirmed before the failing chunk.

A payload-bearing ACK is not discarded while `SEND` waits.  Its payload
is retained in that channel's 536-byte receive queue and returned by the
next `RECV`.  The consumer must drain pending data before another `SEND`
on the same channel; a `SEND` attempted with the queue still occupied is
refused with `NERR_BUSY` (`DE` = bytes sent by earlier chunks of the same
call).  A `SEND` that transmits its whole buffer always reports success,
even when the peer's reply arrived on that last segment's ACK and is
already queued -- the refusal can only ever veto a chunk that has not
gone out, so `NERR_BUSY` never means "your data may or may not have been
sent".  The safe recovery sequence is: `STATUS` (bit 1, `RXPEND`, reports
whether the channel holds deliverable data), `RECV` until `RXPEND`
clears, then repeat the `SEND`.  When the queue is occupied, `RECV`
serves it directly from memory without touching the NIC.  All `RECV`
waits are bounded by the caller's `IY` timeout: the millisecond pacing is
a calibrated CPU loop, not the 50 Hz system tick, so the bound holds
even while interrupts are disabled by the caller.

This remains a deliberately small TCP client, not a general TCP engine:
there is one outstanding segment, no congestion window or fast retransmit,
and close is still best-effort.  Stand-alone utilities compile the compact
legacy send path unless they explicitly define `USE_TCP_RELIABLE_SEND`;
the reliable path is enabled for `UNETRTL.DLL`.

`RECV` also treats `IY=0` consistently for TCP and UDP: it polls the NIC
once and returns idle instead of letting the UDP timeout counter wrap to
approximately 65 seconds.

## Two channels

Channel arguments 0 and 1 have independent TCP/UDP tuples, sequence state,
timeouts, close state and pending TCP data.  When a frame for the other TCP
channel reaches the head of the RTL receive ring, the DLL processes and ACKs
it under that channel's context, then queues its payload before continuing the
original wait.  A foreign UDP datagram remains protected at the ring head
until its owner is read.  `STATUS` reports `UNET_ST_RXPEND`, and `RECV` flag
bit 3 reports `UNET_RXF_XCHAN`, when the other channel needs service.

There is one deferred TCP segment per channel, up to the 536-byte MSS.
Applications should follow the normal UNET rule: service `RXPEND`/`XCHAN`
promptly and do not issue more work on a channel whose receive queue is
already pending.

Developer test:

```
python3 tools/dev/dual_server.py --control-port 9099 --data-port 9100
UNETTEST -2 9100 192.168.7.1 9099
```

The test holds both TCP channels open, streams a counter on channel 1, injects
a control reply on channel 0 during the stream, checks continuity, and verifies
that the control reply survived as pending data.

## Interrupt and window state on return

Every function returns with the ISA window **closed** and interrupts
**enabled**.  A consumer that calls the DLL with interrupts disabled
will get them back enabled.  The ESP backend behaves the same way,
for the same reason: both use the shared `ISA_OPEN`/`ISA_CLOSE`
pair, and the system's 50 Hz interrupt must be serviced between
chip accesses.

`UNETRTL.DLL` is published at the repository root and ships in both
the release archive and the floppy image, so a consumer can take the
ready-built file without installing the assembler or libman.  Its L1
header records the ABI line in the numeric version field and the full
package revision in the 15-byte text tag, for example
`UNETRTL v0.2.39`.
