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

For running `UNETTEST.EXE` scenarios against this DLL in MAME or on real
hardware, see `docs/UNETRTL_TESTING_RU.md`.

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

The DLL locates the card the same way every utility does, through
`NET_RTL_HW`, and **honours `NET_RTL_RESET`**.  That matters: on a clone
whose NE2000 board reset port stalls the ISA bus cycle, a DLL doing the
hard reset freezes the machine the moment a consumer initialises the
network, with no diagnostic of any kind.  Builds up to 0.2.54 had the
soft path compiled out of the DLL for image-budget reasons and did
exactly that; 0.2.55 fixed it by excluding driver entry points the DLL
never calls instead.

The `.EXE` utilities decide for themselves when `NET_RTL_RESET` is
absent: they read the chip ID and pulse `BASE+0x1F` only for a genuine
Realtek.  **The DLL cannot** -- the image has single-digit bytes of
headroom, and the ID probe does not fit.  It defaults to the soft path
instead, which is the same safe direction reached by a cheaper route,
and `NETCFG -i` publishes `NET_RTL_RESET=SOFT` after it meets a clone so
the DLL normally gets an explicit answer anyway.  An explicit
`RTL_RESET=HARD` is still honoured here.

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
- Keep at least ~256 bytes of free stack across a call.  The stack
  itself may live anywhere, WIN0 (0x0000..0x3FFF) included: the
  functions that page the cold overlay over WIN0 (`RESOLVE`, `PING`,
  and `CONNECT`'s next-hop lookup) switch to a private stack for the
  duration, so the remap never runs on the caller's stack.
- The library is not reentrant; make one call at a time.

Arguments and results travel in **A, DE, IX and IY** only; `HL` and
`BC` belong to the libman dispatcher.  **Every function returns its
status in A** -- the dispatcher does not propagate the carry flag, so
test `A`, never `CF`.

## What this backend supports

`GETCAPS` reports `0x023F` = `TCP | UDP | RESOLVE | PING | MULTICHAN |
LISTEN | ASYNCSEND`, ABI `0x0100`.

| Capability   | State | Note |
|--------------|-------|------|
| `TCP`        | yes   | channels 0 and 1; `SEND` chunks at the 536-byte MSS |
| `UDP`        | yes   | connected UDP, payload up to the standard 1472-byte MTU |
| `RESOLVE`    | yes   | software DNS; `NERR_NOTSUP` only if `NETINIT` could not reload the DLL's own file (see below) |
| `PING`       | yes   | software ICMP echo |
| `MULTICHAN`  | yes   | channels 0 and 1 may be open simultaneously |
| `LISTEN`     | yes   | passive TCP open; see "Passive open (LISTEN)" below |
| `ASYNCSEND`  | yes   | `SEND` can suspend with `NERR_AGAIN`; see "Non-blocking SEND" below |
| `RAWETH`     | no    | no raw-frame entry point in the current ABI |
| `RXFLOW`     | no    | the card buffers receive in its own ring |

The resolver and ping logic lives in an overlay appended to
`UNETRTL.DLL`'s own file, which `NETINIT` loads by re-reading that
file (looked up in the calling program's home directory, then by the
bare name `UNETRTL.DLL` in the current directory). Keep the DLL under
its original name where the consumer can find it. If the overlay
cannot be loaded, `NETINIT` still succeeds -- TCP/UDP on already
armed or accepted channels and `LISTEN` work in full -- but `RESOLVE`
and `PING` report `NERR_NOTSUP`, and `CONNECT`/`UDPOPEN` fail with
`NERR_CONNECT` because they resolve their host argument (literal IP
addresses included) through the same overlay.

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
  ```

  `st` is the operation that failed, `nerr` the status returned,
  `tcp` and `res` the TCP and resolver failure codes, and `tx` the
  transmit stage plus ISR/TSR/CR.  The values are captured at the
  moment of failure, so `LASTERR` never reports a chip that has since
  recovered.  Unlike earlier builds, this string does not carry a raw
  `CR ISR DCR RCR TCR IMR PSTART PSTOP BNRY CURR` register dump (image
  budget, made room for `LISTEN`); a consumer that needs those reads
  them the same way every stand-alone utility does, via its own
  `@RTL.SNAPSHOT_REGS` call.

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
approximately 65 seconds.  On TCP, one call first waits for a segment using
the caller's `IY`, then drains already available segments with one-tick polls
until the caller buffer is full or the ring is empty.  Data is copied directly
to the caller buffer; only a final partial segment is retained in the existing
per-channel pending slot.  Thus a single TCP `RECV` may return more than the
536-byte MSS while preserving the same ABI and queue limits.  The drain
coalesces its cumulative ACK into one scoped flush; ordinary receive, `SEND`
and foreign-channel processing keep their immediate-ACK behavior.  If that
flush fails after bytes were delivered, those bytes are still returned and
the ACK debt is retried by the next `RECV`; with no bytes to return the call
reports `NERR_HW`.

## Non-blocking SEND

By default `SEND` blocks like any stop-and-wait TCP client: up to four
1-second ACK-wait attempts (see "Bounded TCP retransmission" above)
before it gives up. `SETOPT UNET_OPT_SENDSLICE` (option value in
`DE`) trades that block for a bounded one: `DE=0` restores the
default blocking behavior; any other value is the maximum number of
milliseconds one `SEND` call may wait before returning, clamped to a
50 ms minimum (1..49 are raised to 50; values from 256 upward pass
through unclamped since the low byte alone cannot express them).

While a slice expires with the current attempt's ACK still
outstanding, `SEND` returns `NERR_AGAIN` and `DE` reports the bytes
already confirmed by earlier chunks of the same call -- the
in-flight chunk is neither dropped nor retransmitted yet, so the
consumer's own retransmit timer keeps counting down across repeated
`NERR_AGAIN` calls. The very next `SEND` call on that channel must
pass the *same* buffer pointer and length as the original call (a
resume, not a new send); calling `SEND` with different arguments, or
on a different channel, while a send is suspended returns
`NERR_STATE`. Once the whole four-attempt/four-second budget is
exhausted with no ACK, `SEND` finally reports `NERR_SEND` as usual.

While a `SEND` is suspended, `RECV` on the same channel serves only
data already queued from the pending-payload slot (see "Bounded TCP
retransmission") -- it does not touch the NIC, and a connection that
the peer closed while the send was suspended is not reported as
`NERR_CLOSED` until the send resume completes. `CONNECT`, `UDPOPEN`,
`CLOSE`, `NETDONE`, `NETINIT`, `LISTEN`, `UNLISTEN`, `PING` and
`RESOLVE` all return `NERR_BUSY` while any channel has a suspended
send.

Developer test:

```
python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080
UNETTEST -a 192.168.7.1 8080
```

`UNETTEST -a` SETOPTs a short `SENDSLICE`, `CONNECT`s, then `SEND`s a
~1200-byte payload against the stalling peer above (its receive window
closes shortly after accept, so at least one `SEND` attempt is expected
to suspend); it prints how many `NERR_AGAIN` resumes were needed before
the transfer settled. See `docs/UNETRTL_TESTING_RU.md` for the MAME
walkthrough.

## Passive open (LISTEN)

`LISTEN` (`A`=channel, `DE`=local TCP port 1..65535) arms one closed
channel as a single-backlog server socket; there is only ever one
listening channel across both, and `LISTEN` on a second channel while
one is already listening returns `NERR_STATE`. Progress is entirely
`RECV`-driven: each `RECV` call on the listening channel (or on the
timeout-bounded default when `IY=0`, one poll) checks for an
unsolicited SYN to the armed port, replies with SYN+ACK, and once the
peer's final ACK of the handshake arrives promotes the channel to an
ordinary connected `ST_ESTAB` channel indistinguishable from one
`CONNECT` made -- `STATUS` reports `UNET_ST_LISTEN` while armed, and
once a peer is accepted ORs `UNET_ST_ACCEPT` into the normal
`UNET_ST_CONN | UNET_ST_RXPEND` bits for as long as that inbound
connection stays open. A
data- or FIN-bearing final ACK is not lost at the accept boundary: the
same `RECV` call that completes the handshake immediately re-enters
the normal established-connection path and can return that segment's
payload.

Because progress only happens inside `RECV`, a SYN that arrives while
the consumer is blocked in some other call (`SEND`, `CONNECT` on the
other channel, `PING`, ...) is not dropped -- it is simply not
answered until the next `RECV`, and the peer's own SYN retransmit
timer covers the gap. A second SYN from a different peer while one
handshake is already in progress is not queued (backlog is exactly 1)
and is silently ignored; that peer's own retransmit brings it back
once the first handshake resolves one way or the other.

`UNLISTEN` (`A`=the currently listening channel) stops the server. If
no peer has been accepted yet, this simply closes the socket. If a
peer *has* been accepted (the channel promoted to an ordinary
connection), that connection is left running -- `UNLISTEN` only
detaches the "please re-arm this port" bookkeeping -- and the
consumer closes it separately with `CLOSE` when done. Symmetrically,
closing an accepted connection with `CLOSE` (or its own natural
`NERR_CLOSED`) automatically re-arms the same channel back to
`LISTEN` on the same port, so a simple accept-serve-close loop never
needs to call `LISTEN` more than once. `NETDONE` always tears the
listener down first, so a pending re-arm never outlives it.

Developer test:

```
python3 tools/dev/unettest_listen_client.py --host 192.168.7.2 --port 9000
UNETTEST -l 9000 192.168.7.1
```

(`UNETTEST -l` arms the port immediately; run the client twice -- the
DSS side accepts and serves exactly two peers on the same channel
before `UNLISTEN`, to prove the CLOSE-triggered re-arm above actually
works.) See `docs/UNETRTL_TESTING_RU.md` for the MAME walkthrough.

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

Every function returns with the ISA window **closed** and the caller's
interrupt state **restored exactly as found**: `ISA_OPEN` samples the
caller's IFF2 before disabling interrupts to map the card, and
`ISA_CLOSE` re-enables them only if that sample said they were on.  A
consumer that keeps interrupts enabled across the call (for example to
let a music player's IRQ-driven routine keep running) gets them back
enabled; a consumer that calls in with interrupts already disabled
(running its own critical section) does not have them force-enabled by
the DLL.  Nested `ISA_OPEN`/`ISA_CLOSE` pairs inside a single UNET call
(library-internal close/reopen around a delay or a DSS call) do not
disturb this: only the outermost open records the caller's IFF2, and
only the matching close restores it.

One consequence: `SETOPT CANCELKEYS` and the millisecond pacing delay
inside a wait loop both still run when the caller entered with
interrupts disabled, but the Esc/Ctrl-C/Ctrl-Z poll is inert in that
case -- `DSS_SCANKEY`'s buffer is filled by the 50 Hz system interrupt,
which does not run without interrupts enabled. A consumer that wants
cancel keys to work must keep interrupts enabled around the call.

`UNETRTL.DLL` is published at the repository root and ships in both
the release archive and the floppy image, so a consumer can take the
ready-built file without installing the assembler or libman.  Its L1
header records the ABI line in the numeric version field and the full
package revision in the 15-byte text tag, for example
`UNETRTL v0.3.0`.
