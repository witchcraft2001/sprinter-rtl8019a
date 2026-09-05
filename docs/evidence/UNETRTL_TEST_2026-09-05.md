# UNETRTL.DLL MAME / hardware evidence

See `docs/UNETRTL_TESTING_RU.md` for the scenario commands this checklist
refers to.

- Date: 2026-09-04 / 2026-09-05
- Tester: DmitryM (with agent assistance)
- MAME or real Sprinter/card/slot: MAME, `-isa1 rtl8019as`, `-networkprovider pcap`, feth0/feth1
- `distr/sprinter-rtl8019a.img` SHA-256: `2f1ba8c5c06c64cb1dd90b03d6d6846ea93a9fd08b7528a8335147c626519257`
- Named host interfaces (feth0/feth1 or other): feth0 (MAME NIC), feth1 (host probes/responders)
- DLL under test: `UNETRTL v0.3.0` (`caps=0x023F`, `abi=0x0100`)

## Scenario 0 -- preamble

- [x] Reaches `NETINIT ok` .. `connect ...` without a hang/crash
- [x] `caps=0x023F`, `resolve: 192.168.7.1`, `ping: 29 ms` all printed

Note: the immediately following `Connect failed. lasterr: ... nerr=04`
in this run is expected -- no responder was bound to port 80 for the
preamble-only check; Scenario A below covers a real CONNECT.

## Scenario A -- TCP (CONNECT/SEND/RECV)

- [x] Responder (`unettest_tcp_probe.py --bind 192.168.7.1 --port 80`)
      logged `CONN` + `REQ (... shape=True)` + `REPLIED and closed`
- [x] DSS printed `request sent`, `HTTP/1.0 200 OK` / `Content-Length: 19`
      / `Connection: close`, body `unettest-tcp-probe`, `--- closed ---`
- [x] `--mode abort` baseline: `SEND` succeeds (request goes out), then
      the immediate `RECV` reports `NERR_CLOSED` (`DE=0`) and takes the
      `.recv_closed` short path straight to `--- closed ---` -- correctly
      NOT `NERR_PARAM`. Note: this differs slightly from the doc's literal
      wording ("distinct `receive error`/`lasterr` message") -- a
      peer-RST-before-any-read collapses to the same `--- closed ---` text
      as a graceful close, since `unettest.asm`'s `.recv_closed_data`
      path only prints `MSG_RECV_ERR` for a *non*-OK/non-CLOSED status.
      Behavior is correct (no hang, no NERR_PARAM); doc wording will be
      loosened to match.

## Scenario B -- UDP (`-u`)

- [x] Default 21-byte payload: `udp reply: len=21 data=SPRINTER UNETTEST
      UDP`, `udp echo ok`
- [x] Sized payload at MTU boundary: 1472 bytes echoed correctly
      (zero-copy path), 1473 bytes -> local `nerr=09` (`NERR_PARAM`)
      without touching the wire

## Scenario C -- dual channel (`-2`, MULTICHAN)

- [x] Both `connect control ...` / `connect data ...` lines, `request sent`
- [x] `no reply on our ACK - SEND guard path not hit` (one of the two
      documented outcomes), `data bytes: 4096` + `data stream continuous`
      (no corruption/duplication), `control reply: CONTROL REPLY DURING
      TRANSFER` delivered correctly mid-stream via the foreign-frame path;
      `dual_server.py` log confirms `control reply sent after 2144 data
      bytes` and `data channel closed after 4096 bytes`

## Scenario D -- passive open (`-l`, LISTEN/UNLISTEN)

- [x] Peer 1 accepted/served/closed (re-arms LISTEN automatically)
- [x] Peer 2 accepted/served/closed -- **re-arm confirmed** (this is the
      v0.3.0 find #3 regression check: `FOREIGN_BUSY`/`TARGET_MAC`
      un-aliasing). `unettest_listen_capture.py` + tcpdump on feth1 show
      both peers getting full SYN/SYN-ACK, data, ACK, the
      `UNETTEST LISTEN REPLY` reply, and clean FIN/ACK teardown on both
      TCP streams -- no retransmits, no stalls.
- [x] `unlisten done`

## Scenario E -- non-blocking SEND (`-a`, ASYNCSEND)

- [x] At least one `NERR_AGAIN` resume logged: `resumes needed: 6`
- [x] Transfer settles (`request sent`); stall peer
      (`unettest_asyncsend_stall.py --rcvbuf 700 --stall 1`) drains all
      1200 bytes

Note: reproducing this scenario required disabling macOS TCP
receive-buffer auto-tuning (`sudo sysctl -w net.inet.tcp.doautorcvbuf=0`)
-- with it on, the OS silently overrides any `--rcvbuf` request on the
accepted socket (observed 8576 and 326640 bytes actual vs 1/256/1024
requested), so the DSS side never saw a closed window and `NERR_AGAIN`
never fired. `tools/dev/unettest_asyncsend_stall.py`'s docstring now
documents this. An intermediate run with `--rcvbuf 256 --stall 3`
(window smaller than TCP_MSS=536) correctly triggered repeated
`NERR_AGAIN` with a bounded give-up (`gave up after too many NERR_AGAIN
resumes`, no hang) but never completed the transfer -- both are
consistent/correct behavior, just not the scenario's target shape;
`--rcvbuf 700 --stall 1` (window > MSS, stall short enough that the peer
starts draining well before the app's own resume budget expires) is the
combination that demonstrates full suspend-then-recover.

Console output/screenshots: see chat log 2026-09-04/2026-09-05 (agent
session); MAME screenshots for every step saved under
`~/Yandex.Disk.localized/Скриншоты/2026-09-04_23-44-41` through
`2026-09-05_07-49-54`.

Responder terminal output: captured inline per scenario above (tcp_probe,
udp_echo, dual_server, listen_capture, asyncsend_stall).

tcpdump excerpts: captured for Scenario D via
`unettest_listen_capture.py` (embedded tcpdump on feth1), full
SYN..FIN sequence for both peers with no retransmits.

Final result: **PASS** (all five scenarios, `UNETRTL.DLL v0.3.0`)

New findings: none outstanding on the DLL side. All three v0.3.0
real-MAME bugs found earlier this cycle (`F_UDPOPEN` dest-MAC
corruption, `unettest.asm` double-CLOSE unarming LISTEN, `F_PING`
leaving `FOREIGN_BUSY` dirty) are fixed and reconfirmed here. Only a
test-tooling note was found (macOS `doautorcvbuf` auto-tuning
overriding `SO_RCVBUF`), already documented in
`unettest_asyncsend_stall.py`.
