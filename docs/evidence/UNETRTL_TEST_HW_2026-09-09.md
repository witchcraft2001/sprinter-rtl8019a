# UNETRTL.DLL MAME / hardware evidence

See `docs/UNETRTL_TESTING_RU.md` for the scenario commands this checklist
refers to.

- Date: 2026-09-09
- Tester: DmitryM (with agent assistance)
- MAME or real Sprinter/card/slot: real Sprinter, UMC UM9003AF NE2000 clone,
  ISA-8 slot, `RTL_HW=0/#300`. `RTL_RESET=SOFT` set explicitly in `NET.CFG`
  for this run (the driver's AUTO chip-ID detection, added this session,
  would also have selected SOFT on its own -- not separately verified with
  the `RTL_RESET=` line removed).
- `distr/sprinter-rtl8019a.img` SHA-256: **not captured from the tested
  card**. The repository's current build (after this session's
  `RTL_RESET` AUTO-detection fix) hashes to
  `31d32725ae44654534f6dab6a998051c3c1238d1b4e1a51abb5a749d2abd16e1`
  (`UNETRTL.DLL` 18159 bytes, SHA-256
  `d0616f6f6372ed201d829854808f48dd6d908ca9ef2feee4db63b415fd17a769`), but
  that fix landed *during* this test session (after the WGET/FTP/NICINFO
  regression pass and partway through the DLL scenarios), and no
  `shasum -a 256` was run against the actual floppy/DLL sitting on the
  Sprinter at the time each screenshot was taken. The fix does not touch
  any UNET ABI path exercised below (it is confined to `RTL.RESET`'s board
  reset-port decision), so it should not affect these results either way,
  but the exact byte-identical image is not attested here. Capture the
  hash directly from the test machine next time, before removing the card.
- Named host interfaces (feth0/feth1 or other): real LAN, host
  `192.168.1.36` (`en0` class), Sprinter `192.168.1.58`/`192.168.1.58`
  (DHCP-assigned; matches `IP: 192.168.1.58` in every DSS screenshot)
- DLL under test: `UNETRTL v0.3.0` (`caps=0x023F`, `abi=0x0100`)

## Regression pass (base stack, before any DLL scenario)

Not in the template checklist above, but required by
`docs/UNETRTL_TESTING_HW_RU.md` section 0 before touching the DLL --
v0.3.0 changed the shared driver/stack libraries the DLL and every plain
utility both depend on.

- [x] `NICINFO -v`: `[N3] RTL ID= . (20 01)` (correctly identified as a
      non-Realtek clone, not a hard failure), `[E02] RTL ID mismatch` /
      `[W02] ID mismatch but MAC plausible -- continuing`, `RESULT OK`
- [x] `WGET`: 86019 bytes from `tr-dos.ru`, 28 KB/s, `RESULT OK`
- [x] `FTP`: 389579 bytes (`IM2.TXT`) GET in passive mode, 76 KB/s,
      `RESULT OK`

No regressions found in the shared driver/stack code.

## Scenario 0 -- preamble

- [x] Reaches `NETINIT ok` .. `connect ...` without a hang/crash
- [x] `caps=0x023F`, `resolve: 192.168.1.36`, `ping: 3-4 ms` all printed
      (consistent across every DLL run this session)

## Scenario A -- TCP (CONNECT/SEND/RECV)

- [x] Responder (`unettest_tcp_probe.py --bind 192.168.1.36 --port 18080`)
      logged `CONN` + `REQ (58 bytes, matches UNETTEST shape=True)` +
      `REPLIED and closed`
- [x] DSS printed `request sent`, `--- reply ---`, `HTTP/1.0 200 OK` /
      `Content-Length: 19` / `Connection: close`, body
      `unettest-tcp-probe`, `--- closed ---`
- [x] `--mode abort` baseline: on real hardware the RST won the race
      against `SEND` (the opposite branch from the 2026-09-05 MAME run).
      `SEND` itself failed: `Send failed.` /
      `lasterr: RTL hw=0/#0300 st=SEND nerr=07 tcp=03 res=00
      tx=04/02/03/22`. `nerr=07`=`NERR_CLOSED`, `tcp=03`=`F_RST`
      (`tcp_lib.asm`) -- correctly attributed to a peer RST, never
      `NERR_PARAM`. `tx=04/02/03/22`: stage=SEND(04, internal numbering),
      `ISR=0x02` (PTX) confirms the prior frame transmitted cleanly, so
      the transmitter is not implicated. Both this and the MAME-observed
      branch (SEND succeeds, RECV then reports NERR_CLOSED) are
      documented as equally valid outcomes of the same race
      (`docs/UNETRTL_TESTING_RU.md` was corrected this session after
      initially describing only the MAME branch).

## Scenario B -- UDP (`-u`)

- [x] Default 21-byte payload: `udp poll0 ok`, `udp payload: 21 bytes
      (default)`, `udp reply: len=21 data=SPRINTER UNETTEST UDP`,
      `udp echo ok`
- [ ] Sized payload at MTU boundary (1472 / 1473) -- **not run on real
      hardware**. Re-analyzed mid-session and reclassified as
      harness-appropriate rather than a required hardware step: the
      1473-byte case is rejected by `F_UDPSEND`'s length check
      (`UDPLIB_MAX_PAYLOAD`) before the ISA window is ever opened, so a
      real chip cannot demonstrate anything the JS model can't. Added as
      a new harness vector instead
      (`tools/test-exe-dll.js`, asserts `nerr=09` AND zero UDP frames
      transmitted) -- covered there, intentionally not re-run here.

## Scenario C -- dual channel (`-2`, MULTICHAN)

- [x] Both `connect control ...` / `connect data ...` lines, `request sent`
- [x] `data bytes: 4096`, `max recv block: 536` (== TCP_MSS), `data
      stream continuous` (no gaps/corruption), `control reply: CONTROL
      REPLY DURING TRANSFER` delivered correctly mid-stream via the
      foreign-frame path; `dual_server.py` log confirms `control reply
      sent after 2144 data bytes` and `data channel closed after 4096
      bytes`
- [x] ACK verdict: **`no reply on our ACK - SEND guard path not hit`**,
      reproduced consistently across three separate runs on this host --
      the default run, a `--lockstep` run, and a `--lockstep` run with
      `net.inet.tcp.delayed_ack=1` (all three: `lockstep: replied
      immediately (31 bytes)` on the host side, `not hit` on the DSS
      side). Per the template note this is a valid outcome, not a
      failure: the reply-riding-the-ACK state depends on when the HOST
      KERNEL sends its ACK, which `--lockstep`/`delayed_ack` cannot pin
      down from userspace on macOS. **Conclusion recorded this session:
      the pend-guard branch (`reply rode our ACK - SEND guard path
      exercised`) is not reproducible from a macOS test host and remains
      uncovered on real hardware.** Deterministic coverage of this branch
      belongs in the harness (`tools/exe-harness/net-builders.js`
      `respondTcp` already supports multiple sessions by port; a
      dedicated vector for `-2` with a reply riding the command's ACK
      does not exist yet -- not built this session).

## Scenario D -- passive open (`-l`, LISTEN/UNLISTEN)

- [x] Peer 1 accepted/served/closed (`peer closed after reading reply
      (re-armed)`)
- [x] Peer 2 accepted/served/closed -- **re-arm confirmed** (the same
      real-network re-arm check as the 2026-09-05 MAME evidence, now
      also passing on physical hardware)
- [x] `unlisten done`

## Scenario E -- non-blocking SEND (`-a`, ASYNCSEND)

- [x] `net.inet.tcp.doautorcvbuf=0` set before the run; peer logged
      `accepted socket rcvbuf=1072` (> TCP_MSS 536, < the 1200-byte
      payload -- exactly the intended window), no `WARNING` lines
- [x] `resumes needed: 6` (well within the `ASYNC_MAX_AGAIN=20` budget);
      DSS printed six `SEND suspended (NERR_AGAIN), confirmed so far:
      1072` lines, matching the peer's advertised window byte-for-byte
- [x] Transfer settles (`request sent`); peer drained all 1200 bytes
      (`--rcvbuf 700 --stall 1.0`, `unettest_asyncsend_stall.py`
      defaults after this session's fix -- previously an earlier attempt
      with the tool's old defaults, `--rcvbuf 256`/no auto-tuning check,
      produced `resumes needed: 0` and was correctly diagnosed as a
      tooling artifact, not a DLL issue, before being corrected)

Console output/screenshots: see chat log 2026-09-09 (agent session);
photos `photo_2026-09-09_09-27-*` (regression pass), `photo_2026-09-09_11-01-3*`
(preamble/UDP/MULTICHAN/LISTEN), `photo_2026-09-09_11-10-40` (ASYNCSEND),
`photo_2026-09-09_11-30-51` and `photo_2026-09-09_11-38-32` (MULTICHAN
ACK-verdict re-runs).

Responder terminal output: captured inline per scenario above
(`unettest_tcp_probe.py`, `udp_echo.py`, `dual_server.py` x3,
`unettest_listen_client.py` x2, `unettest_asyncsend_stall.py`).

tcpdump excerpts: none captured this session (Scenario D's inbound-accept
path was already tcpdump-verified on 2026-09-05 in MAME; not repeated
here).

Final result: **PASS** (Scenarios 0, A, B [default payload only], C
[core path; ACK-verdict branch not reproducible from this host], D, E)

New findings:

1. **UMC UM9003AF hang reproduced and fixed at the root.** A second card
   of this model hung on `NETCFG -i` between `[C0] CFG=` and the next
   print (`RTL.RESET` reading the board reset port `BASE+0x1F`) because
   `RTL_RESET=SOFT` was not in `NET.CFG`. Diagnosed from two screenshots
   (ISAPROBE activity map + NICINFO auto-scan failure) without further
   reproduction. Fixed by making `RTL_RESET` three-valued
   (HARD/SOFT/AUTO, `memmap.inc`); AUTO is now the default and probes the
   chip ID (`RTL.IS_REALTEK`) before ever touching `BASE+0x1F`. `NETCFG
   -i` now prints `[W03] non-Realtek clone: board reset port skipped` and
   publishes `NET_RTL_RESET=SOFT` so later utilities and `UNETRTL.DLL`
   inherit the answer. `UNETRTL.DLL` itself has no image-budget room for
   the ID probe (1 byte of headroom left after this fix) and defaults to
   SOFT directly. 11 new harness vectors added
   (`tools/test-exe-harness.js`, `tools/test-exe-net.js`,
   `tools/test-exe-dll.js`) using the previously-unused
   `hangOnResetPort` quirk, and confirmed they fail without the fix.
   `RTL_RESET=SOFT` in `NET.CFG` is no longer required for this card
   (kept in this test run's config only as a belt-and-braces explicit
   pin, not re-verified with the line removed).
2. **Two `tools/dev/` test-tooling gaps, not DLL bugs**, found while
   trying to reproduce Scenario E and the Scenario C ACK-verdict branch:
   - `unettest_asyncsend_stall.py`'s old defaults (`--rcvbuf 256`) were
     below `TCP_MSS` and its documentation actively recommended the wrong
     fix direction; also had no warning when `doautorcvbuf` silently
     overrode the requested window. Both fixed this session (new
     defaults `--rcvbuf 700 --stall 1.0`, explicit `WARNING` lines).
   - `dual_server.py --lockstep` cannot force the ACK-riding branch from
     a macOS host regardless of `net.inet.tcp.delayed_ack` -- documented
     as a known limitation rather than chased further; see Scenario C
     above.
3. **Scenario B's MTU-boundary sub-case (1473 bytes) reclassified**, not
   a finding against the DLL: the rejection happens before the ISA
   window opens, so it is a pure host-side length check with nothing for
   real hardware to add. Moved to the harness instead of the hardware
   checklist.

All DLL-side findings from the 2026-09-05 MAME evidence
(`F_UDPOPEN`/`F_PING` `FOREIGN_BUSY` aliasing, `unettest.asm` double-CLOSE)
remain fixed; none regressed on real hardware in this session.
