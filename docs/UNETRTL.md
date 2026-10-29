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
Realtek.  **The DLL cannot** -- the image has very little
headroom, and the ID probe does not fit.  It defaults to the soft path
instead, which is the same safe direction reached by a cheaper route,
and `NETCFG -i` publishes `NET_RTL_RESET=SOFT` after it meets a clone so
the DLL normally gets an explicit answer anyway.  An explicit
`RTL_RESET=HARD` is still honoured here.

The DLL also reads the canonical `NET_RTL_TYPE=NE1000|NE2000` value written
by `NETCFG -i` or `IFUP`.  NE1000 selects packet RAM at `2000h` and enables
the DP8390 remote-write preparation sequence.  A missing value keeps the
legacy NE2000 default; an invalid value makes `NETINIT` fail with
`NERR_NONET`.  The DLL accepts only canonical `NET_RTL_HW` syntax.

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
| `TCP`        | yes   | channels 0 and 1; receive MSS 536, outbound `SEND` chunks 536 bytes |
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
- **A full TCP receive queue does not refuse `SEND`.** The DLL advertises
  zero receive space while it continues to process ACKs of outgoing data.
  `NERR_BUSY` still applies to unrelated operations during suspended SEND.
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
  recovered.  Since 0.3.8 that is true of the whole line: every error
  return formats it there and then, and later calls -- successful ones
  included -- leave it alone.  Before 0.3.8 only `tx` was captured and
  the rest was read live, so draining a response after a failed `SEND`
  turned `st=SEND nerr=07` into the drain's own `st=RECV nerr=00`.
  A consumer may therefore run its recovery (reading whatever the peer
  queued, closing the channel) before asking for the diagnostic.  The
  line is replaced only by the next failed call, whichever function
  that is.  Until the first failure `LASTERR` formats live state on
  every call, so polling it on a healthy link returns a current line
  rather than nothing.  Unlike earlier builds, this string does not carry a raw
  `CR ISR DCR RCR TCR IMR PSTART PSTOP BNRY CURR` register dump (image
  budget, made room for `LISTEN`); a consumer that needs those reads
  them the same way every stand-alone utility does, via its own
  `@RTL.SNAPSHOT_REGS` call.

## Bounded TCP retransmission

Since 0.4.2, TCP SEND respects the peer's advertised window as well as the
536-byte outbound MSS. Partial ACKs move the next transmission to the first
unconfirmed byte. `DE` always counts the confirmed prefix of the original
call, from zero through the requested length, including across `NERR_AGAIN`.
Window advertisements use per-channel SND.WL1/WL2 freshness checks and
modulo-32 sequence arithmetic. Acceptable empty ACKs create no ACK reply or
receive-ACK debt; data, FIN, duplicates and probes still receive ACKs.

A missing segment or ACK permits four transmissions with approximately one
second of polling per attempt. Exhaustion returns `NERR_SEND`; NIC transmit
failure returns `NERR_HW`, and cancellation returns `NERR_CANCEL`.

A closed peer window instead starts persist: one-byte probes after roughly
1, 2, then 4 seconds, with subsequent intervals capped at 4 seconds. Replies
keep the connection alive without consuming the ordinary data retry budget;
four consecutive unanswered probes fail the operation. An opening window
resumes the unconfirmed suffix, including when its original update was lost.
See [RFC 9293 section 3.8.6.1](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.8.6.1).
These intervals count poll iterations; conversion to system timers is separate
work. On the 2026-10-20 Battleship/MAME stand, a 50-tick SEND slice took
up to 71 ms, and the 2/4-second probe budgets took about 2.70/5.37 seconds
(roughly 1.35 times nominal). These are stand measurements, not a portable
wall-clock guarantee; CPU speed, packets and consumer IRQ handlers affect it. `SENDSLICE` budgets also include ACK/window-update processing rather than
restarting on each packet. With `SENDSLICE=0`, a living peer may keep SEND
blocked in persist indefinitely; each internal wait is bounded and the
existing `CANCELKEYS` mechanism can interrupt it. With a nonzero slice,
resume `NERR_AGAIN` using the same channel, pointer and length. In RTL,
`NERR_AGAIN` with a nonzero SENDSLICE also means the slice was spent
processing ACKs/window updates, or another channel's UDP datagram needs
draining; it does not imply silence. With SENDSLICE=0, SEND never returns
AGAIN: it discards a foreign UDP head and continues the TCP wait. The next
RECV on that UDP channel reports `UNET_RXF_LOST`. CLOSE also discards a blocking foreign UDP head and leaves LOST on the
UDP channel if it stays open. NETDONE tears both channels down. Neither
abandons the FIN wait because of that UDP head.
The frozen `unet.inc` comments retain the original ESP silence wording.
This section specifies the RTL behavior without changing the shared ABI.

After a final SEND timeout, NIC transmit error or cancellation, the channel
stays occupied until `CLOSE` or `NETDONE`. Further SENDs return
`NERR_CLOSED`, `DE=0`, without transmitting. RECV drains already queued data
and then returns `NERR_CLOSED`; STATUS clears `UNET_ST_CONN`. CLOSE sends
RST and frees the slot, or rearms its listener. This also applies when the
first attempted transmission failed. Orderly peer FIN/RST keep the separate
handling below. A late peer FIN processed while receiving on the other
channel cannot restore CONN or turn a terminal SEND failure into a half-close.

Since 0.4.6, an aborted channel with no queued bytes does not assert
`RXPEND` or cause `XCHAN` on the other channel. A partial drain retains both
hints while bytes remain. The slot itself is still reserved: after a final
SEND timeout, NIC error, cancellation or non-covering FIN, the client
must call CLOSE (or NETDONE) to release it or rearm LISTEN. Repeated RECV
returns CLOSED/DE=0 and does not perform that cleanup. A deferred orderly
peer FIN still requests receive service until RECV reports EOF. The peer-RST
release/rearm path described below is unchanged.
An aborted outbound TCP channel with no queued bytes, not yet explicitly
closed, has STATUS=0, just like a free slot; CONNECT and LISTEN on it return
`NERR_STATE` until CLOSE. Do not use STATUS alone to decide that such a
slot can be reused.

Since 0.3.8, a peer FIN that arrives during that ACK wait **and leaves the
current chunk unacknowledged** is reported as `NERR_CLOSED`, not `NERR_SEND`.
A server may answer before it has consumed the body it is still being sent --
an HTTP `4xx` refusing a WebDAV `PUT`, for example -- and then close.  Those
response bytes are already saved by the receive sink, so `SEND` only names
the outcome: it does not release the channel or clear the queue.  `DE` is the
acknowledged prefix, the following `RECV` calls return the response, and the
`RECV` after the last byte returns `NERR_CLOSED`. Since 0.4.5 this failed
SEND also marks the stream aborted: subsequent SENDs return `NERR_CLOSED`,
`DE=0`, without reusing the unacknowledged sequence range. STATUS clears
CONN; CLOSE/NETDONE releases or rearms the channel after sending abort resets.

A FIN whose ACK *does* cover the whole chunk is not an error at all: that
`SEND` succeeds with its full length, the remaining chunks of the same call
are still sent to the half-closed peer, including across `NERR_AGAIN` resumes.
Further SENDs are allowed while that peer can still read. STATUS retains
`UNET_ST_CONN` until RECV drains the saved response and releases the channel. A peer RST discards the remaining queue, releases or rearms the channel,
and prohibits further SEND on that stream (`NERR_STATE` on the released or
rearmed slot). Bytes already copied by public
RECV remain visible with `NERR_CLOSED` and their actual DE count. A foreign
RST performs the same queue cleanup and listener rearm; STATUS cannot retain
a stale RXPEND on a released slot.

`LASTERR` reports `tcp=08` for the FIN case (`F_CLOSED`); before 0.3.8 the
FIN left no reason at all, so the pair read `nerr=05 tcp=00` and no consumer
could tell a refusal from a dead peer.

## Closing a channel

Since 0.3.10, `CLOSE` tells the peer the connection is over in a way it can
actually act on, and reports whether it managed to.

When the send stream is fully acknowledged and has not been aborted, `CLOSE` sends `FIN+ACK` and waits
for the peer to acknowledge it, transmitting the FIN at most three times
(two retransmissions) with
a 500-poll-tick wait each. Non-covering ACKs consume the same attempt
budget; they neither prove the FIN arrived nor restart the wait. Unread
incoming data instead causes the abort described below. Only a cumulative ACK covering the FIN or a peer RST completes it.  On a healthy link the acknowledgement arrives in about a
millisecond and the close costs nothing measurable; a peer that has gone away
caps the wait at 1500 polling ticks (see the timing caveat above).  The wait runs through the normal receive path, so a
segment for the OTHER TCP channel arriving mid-close is queued --
the case that made the pre-0.3.8 blind drain unusable (FTP's `226 Transfer
complete` on the control connection while the data connection was closing).

When a `SEND` ended with bytes transmitted but unacknowledged -- it was
cancelled, it exhausted its retries, or a retransmission failed in the NIC
after the first copy went out -- whether the peer took those bytes is
unknowable from this side, and a FIN is wrong either way: at the low sequence
number it is an old duplicate the peer ignores, at the high one it is an
out-of-order segment that never reaches end-of-stream.  Both leave the peer
waiting for the rest of a request body that is never coming, holding whatever
that request locked -- which is how a cancelled WebDAV `PUT` used to produce
`HTTP 423 Locked` on the retry.  `CLOSE` therefore **aborts** such a
connection per RFC 1122 4.2.2.13, sending `RST+ACK` at both candidate
sequence numbers, since an RFC 5961 peer honours a reset only at exactly its
`RCV.NXT`.

A close with unread received bytes also aborts through RST. If data arrives
during the FIN wait, the receive path may ACK it, but CLOSE follows with RST
to tell the peer those bytes were not read by the application. This includes
a data-bearing ACK that covers our FIN.

`CLOSE` reports what the peer can be known to have learned:

| Return | Meaning |
| --- | --- |
| `NERR_OK` | FIN cumulatively acknowledged, peer RST received, or local abort resets transmitted |
| `NERR_TIMEOUT` | FIN remained unacknowledged after three bounded attempts, even if other traffic arrived |
| `NERR_CANCEL` | the user ended the wait before any answer arrived |
| `NERR_HW` | a FIN or RST never reached the wire at all |

`NERR_CANCEL` is worth handling separately from `NERR_TIMEOUT` by a consumer
that armed `UNET_OPT_CANCELKEYS`: the Esc that cancelled a transfer is still
in the DSS keyboard buffer when the `CLOSE` that follows runs, so the first
tick of the FIN wait consumes it and the close returns immediately.  Nothing
was confirmed in that case either -- clear the key, or accept that the peer
may not have been told.

Both RST transmissions of an abort are accounted for, not just the last:
only one of the two sequence numbers is the peer's `RCV.NXT`, and which one
cannot be known here, so a reset that never left the NIC may well have been
the one that would have been honoured.

`NETDONE` reports the same, naming whichever channel failed.  The channel is
released locally in every case -- there is no state left to retry from -- but
a consumer that must know the peer was told can now see that it was not, and
`LASTERR` carries the underlying TCP reason.  `CLOSE` stays idempotent, and a
close against an unreachable peer spends the full 1500 polling ticks before reporting
`NERR_TIMEOUT`.

The released channel does not retain a TIME_WAIT receiver. A peer FIN
arriving after the ACK of our FIN and local release is still ignored; this
release does not claim to fix that older limitation.

Since 0.3.1, every received TCP payload is saved BEFORE advancing the receive
sequence or sending its ACK. During public `RECV`, bytes go to the caller
and then to its pending queue. During `SEND` or foreign-channel processing,
only the owner's 536-byte queue is available. If a segment exceeds capacity,
only the fitting sequential prefix is saved and acknowledged. The peer must
retransmit the remainder; overlapping retransmissions are trimmed. FIN is
accepted only after all preceding payload is saved. A failed ACK leaves the
saved bytes available and an ACK debt that the next `RECV` retries.

The advertised window is the available caller capacity plus unused queue
tail, capped at 2680 bytes. Outside public `RECV`, only queue space counts;
a full queue advertises zero. Draining the queue reopens its window with an
ACK update. Partial reads retain the queue's offset until fully drained.
Window calculation uses the current channel and never inherits another
channel's receive capacity. Outgoing ACK processing is independent of the
ability to receive payload, including stale-sequence and zero-window frames.
A successful `SEND` always returns its full requested length. Final received
bytes are delivered before closure or with `NERR_CLOSED`.

Since 0.3.2, every active TCP `RECV` also sends a pure ACK before waiting for
new data. This advertises the capacity lent by that call's buffer after the
previous call retracted it. For example, an empty 536-byte pending queue plus
a 2048-byte caller buffer advertises 2584 bytes; a caller capacity of 2144
bytes or more reaches the 2680-byte cap. The final cumulative ACK still
excludes the caller buffer, so no peer data is acknowledged against storage that disappears
when the DLL returns. Between calls the window can therefore be 536 bytes, but
the next active call reopens it before polling the NIC. If this opening ACK
cannot be transmitted, `RECV` returns `NERR_HW`, `DE=0`, `IX=0`, preserves the
driver diagnostic for `LASTERR`, and leaves the ISA window closed.

Since 0.3.3, an active `RECV` is capacity-driven and continues bounded short
polls until the caller buffer is full, no next frame arrives within two ticks,
or FIN is reached. When a segment crosses the caller boundary, the fitting
prefix is copied directly and the tail is committed to the 536-byte pending
queue before ACK. A following call coalesces that tail with new data. If FIN
was already saved, pending bytes are returned before CLOSED.

Version 0.3.4 experimented with receive MSS 512 and window 2560 to align SNC's
2048-byte buffer. Version 0.3.5 restored MSS 536/window 2680. Version 0.3.6
tested Ethernet receive MSS 1460, but that geometry regressed the synchronous
DLL path: after each public RECV returns, only the 536-byte durable queue
remains valid, and the next 2048/2144-byte transient caller window is too short
to sustain a whole-number 1460-byte pipeline. Version 0.3.7 therefore keeps
UNETRTL receive and outbound chunks at 536 bytes. Direct clients, whose buffer
survives for the connection, retain MSS 1460/window 4380. Arbitrary positive
DLL RECV sizes remain covered by the pending-tail/retransmission path.

All waits remain bounded. While SEND is suspended, RECV serves saved bytes
from memory; the next active network operation publishes freed capacity.

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
536-byte pending-queue size while preserving the same ABI and queue limits. The drain
coalesces its cumulative ACK into one scoped flush; ordinary receive, `SEND`
and foreign-channel processing keep their immediate-ACK behavior.  If that
flush fails after bytes were delivered, those bytes are still returned and
the ACK debt is retried by the next `RECV`; with no bytes to return the call
reports `NERR_HW`.

## Non-blocking SEND

By default `SEND` blocks through ordinary ACK retries and through persist
while a peer answers zero-window probes (see "Bounded TCP retransmission"
above). `SETOPT UNET_OPT_SENDSLICE` (option value in
`DE`) trades that block for a bounded one: `DE=0` restores the
default blocking behavior; any other value sets a nominal millisecond
poll budget for one `SEND` call, clamped to at least 50 ticks (1..49 are
raised to 50; values from 256 upward pass through unclamped). This is not
a wall-clock bound; see the measured timing factor above.

While a slice expires with the current attempt's ACK still
outstanding, `SEND` returns `NERR_AGAIN` and `DE` reports the bytes
already confirmed, including a partial ACK of the current chunk. The
unconfirmed suffix remains pending and the DLL's retry/persist budget
continues across repeated `NERR_AGAIN` calls. The very next `SEND` call on that channel must
pass the *same* buffer pointer and length as the original call (a
resume, not a new send); calling `SEND` with different arguments, or
on a different channel, while a send is suspended returns
`NERR_STATE`. Four ordinary unanswered transmissions, or four consecutive
unanswered persist probes, finally return `NERR_SEND`. A living peer with
a closed window has no overall four-second limit.

While a `SEND` is suspended, TCP `RECV` on either channel serves only
data already queued from its pending-payload slot (see "Bounded TCP
retransmission"). A listening channel does not advance accept. These calls
do not touch the NIC, and a connection that
the peer closed while the send was suspended is not reported as
`NERR_CLOSED` until the send resume completes. `CONNECT`, `UDPOPEN`,
`NETINIT`, `LISTEN`, `UNLISTEN`, `PING` and `RESOLVE` return `NERR_BUSY`
while any channel has a suspended SEND. Since 0.4.3, CLOSE on its owner
explicitly cancels that SEND, sends abort resets and frees/rearms the channel.
The abandoned SEND has no further byte-count result and must not be resumed.
CLOSE on the other channel returns `NERR_BUSY`; NETDONE cancels the pending
SEND and tears down both channels. FINI (the libman free hook) also cancels
a suspended SEND before teardown, including a zero-window wait before any
byte was transmitted; unloading cannot present a truncated stream as EOF.
UDP RECV on the other channel may drain a datagram only when it is at the
head of the NIC ring, then the consumer resumes the original TCP SEND. An
ACK/FIN/RST for the suspended TCP channel at that head blocks UDP RECV:
it returns no data with XCHAN until SEND resumes. This
UDP RECV honors its own IY budget and may wait for that entire budget. UDP
SEND on the other channel is also allowed while TCP SEND is suspended. TCP
ACK/FIN/RST for a pending SEND stay reserved for that resume.

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
it under that channel's context, saving its payload before ACKing and continuing the
original wait. A foreign UDP datagram remains protected at the ring head
until its owner is read during RECV or a sliced SEND. Blocking SEND and
CLOSE may instead discard that UDP head with a LOST notification, as
described above.  `STATUS` reports `UNET_ST_RXPEND`, and `RECV` flag
bit 3 reports `UNET_RXF_XCHAN`, when the other channel needs service.

There is one 536-byte deferred TCP queue per channel. A larger incoming segment
is accepted only as far as caller space plus that queue permit; an unaccepted
suffix is not acknowledged and is recovered by overlap-aware retransmission.
Applications should follow the normal UNET rule: service `RXPEND`/`XCHAN`
promptly and do not issue more work on a channel whose receive queue is
already pending.

For a terminal SEND failure, drain any saved response and then call CLOSE.
An empty aborted channel has no further receive work, so its error state
alone does not keep `RXPEND`/`XCHAN` set. Receiving CLOSED does not release
that slot; CLOSE/NETDONE is required even after the hints have cleared.

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
`UNETRTL v0.3.8`.

## Complete early-response regression (0.3.1)

Developer floppy: `UNETTEST -r SLICE HOST PORT`. Use `SLICE=0` for blocking
SEND or `25` for sliced SEND. The host helper is
`python3 tools/dev/unettest_response_server.py --port 8080`.
The request is one complete PROPFIND with an empty body. The expected reply
is 8233 bytes, beginning `HTTP/1.1`, with an 8192-byte body (byte i = i & 255)
and IEEE CRC32 `62763860`. The test checks every byte, length, checksum,
absence of LOST, and mandatory EOF, with bounded SEND resumes and 300
receive polls of at most 100 ms each. It prints first8, length, CRC32,
resume count and RESULT OK/FAIL. Exit 0 means verified; exit 3 means a
communication/content failure. Other normal UNETTEST exit codes still apply.
A socket helper guarantees these bytes, but cannot force TCP segmentation
or guarantee a nonzero resume count. The host harness controls ACK/data/FIN
geometry and delay deterministically. MAME/real-card and original SNC
WebDAV acceptance require their own run and packet capture.

## Receive-window throughput regressions (0.3.2--0.3.7)

The host DLL harness uses a cumulative-ACK/window-aware peer for two 12000-byte
streams, one on each TCP channel. It issues repeated blocking `RECV` calls with
2048-byte buffers, compares every byte, requires every non-final result to be
exactly 2048 bytes, rejects any `LOST` flag, and checks the wire transition
from the final durable window to the next call's larger active window. The
same suite keeps the foreign-channel capacity checks, failed-ACK cases,
payload/FIN ordering, retransmission, and WIN1/WIN2 relocation coverage. A
dedicated transmit fault on the opening ACK must return `NERR_HW` with
preserved `LASTERR` state and a closed ISA window.

## Reproducing release 0.4.6

Use sjasmplus 1.22.0 and sprinter-mkdll from libman 1.3, then run
`make test-host package image`. `tools/build.sh` fixes the L1 header date to
`2026-10-20`, uses the tag from `src/include/version.inc`, disables compression,
and appends the assembled cold overlay. Run `make build` again and compare
`shasum -a 256 UNETRTL.DLL`; identical inputs reproduce the DLL byte for byte.
The TCP fix lives in the main L1 image and needs no additional code page.
Existing receive queues and the 1472-byte UDP payload limit are retained.

Since 0.4.5, a duplicate or out-of-order FIN is acknowledged at the current
RCV.NXT but cannot report EOF or terminate SEND. Only a newly accepted FIN
can do so; a later ordinary ACK in CLOSE_WAIT still advances SEND. Host
regressions cover missing data before FIN, a duplicate FIN after half-close,
and a fresh SEND after a non-covering accepted FIN, in WIN1/WIN2 with
blocking and sliced SEND.
The channel-state address helper also increments the full HL pointer, so
moving CH_STATE across a 256-byte boundary cannot corrupt adjacent code.
Since 0.4.6 the pending-length/offset, closed and lost helpers also advance
the full HL pointer. The unreachable repeated ACK_WAIT_ACTIVE check in the
DLL receive-return path was removed; the sender and persist logic are unchanged.

The frozen `unet.inc` mirror still has obsolete backend-specific capability
comments. Use GETCAPS: UNETRTL returns `0x023F`, including MULTICHAN, LISTEN
and ASYNCSEND. Updating those shared comments requires updating the canonical
contract in sprinter_wifi first; this release keeps the mirror unchanged.

For this build's verification record, see `docs/evidence/UNETRTL_046/README.md`.
Earlier Battleship n3 acceptance summaries are in
`docs/evidence/UNETRTL_044/README.md`. The runner uses a private stand copy
and a 60-second caller deadline so a 30-second persist wait retains its
original SEND buffer.
Raw logs, captures and machine-readable reports are local outputs under
`build/evidence/unetrtl` by default; they are not stored in Git.


Since 0.4.4, DNS rebuilds each retransmission from the original hostname and
transaction ID. Long queries borrow temporary RX scratch, which unrelated
broadcast traffic may overwrite while waiting; that scratch is never reused
as the next query. The retry limit and XID stay unchanged. Tests lose one or
two requests, receive broadcast frames, and compare every retransmitted byte
for both short and maximum-length names in WIN1/WIN2.

The intermittent CBL refill gaps reported for both RTL and UNET509B have
been traced by the stand maintainer to MAME's shared Z84C015 IRQ0 input:
internal-device CLEAR can overwrite an asserted external interrupt request.
No IRQ behavior was changed in this DLL. Emulator audio gaps alone do not
establish an ISA/IFF regression; real hardware remains the final check.

## Independent SEND work quantum (0.4.7)

With nonzero SENDSLICE, TCP SEND yields between individual wire-send and
receive steps, even when the peer responds immediately. This independent
work limit applies to the first call, resumes and transitions between MSS
chunks. SENDSLICE keeps its option number, stored value and minimum of 50;
zero still selects blocking SEND. No new option or capability is required.
NERR_AGAIN can therefore occur before any ACK has been processed (DE=0).
Always resume with the original channel, pointer, length and unchanged bytes.
RECV/STATUS may be serviced between continuations. The confirmed prefix and
retry/persist state survive those calls. The work limit does not reset retry
timeouts or count a yield as a retransmission.

The implementation parks the next instruction inside the DLL; it does not
use the consumer's CTC or allocate another page. Driver TX/DMA error waits
and RX overflow recovery retain their existing independent bounds. The
10 ms target concerns a functioning NIC and requires inclusive dispatcher
plus DLL timing in MAME; model CPU cycles alone cannot establish that bound
or physical-input-to-PRESENT latency. Hardware timing is separate acceptance.
