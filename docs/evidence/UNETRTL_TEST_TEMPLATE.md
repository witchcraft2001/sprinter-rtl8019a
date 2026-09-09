# UNETRTL.DLL MAME / hardware evidence

See `docs/UNETRTL_TESTING_RU.md` for the scenario commands this checklist
refers to.

- Date:
- Tester:
- MAME or real Sprinter/card/slot:
- `distr/sprinter-rtl8019a.img` SHA-256:
- Named host interfaces (feth0/feth1 or other):

## Scenario 0 -- preamble

- [ ] Reaches `NETINIT ok` .. `connect ...` without a hang/crash
- [ ] `caps=0x023F`, `resolve: <ip>`, `ping: <N> ms` all printed

## Scenario A -- TCP (CONNECT/SEND/RECV)

- [ ] Responder logged `CONN` + `REQ (matches UNETTEST shape=True)` +
      `REPLIED and closed`
- [ ] DSS printed `request sent`, the HTTP reply headers, `--- closed ---`
- [ ] `--mode abort` baseline: SEND/RECV on a reset connection never
      reports `NERR_PARAM`.  Either operation may catch the RST first
      and both are a pass: `SEND` succeeds and `RECV` then prints
      `--- closed ---` directly (typical under MAME), or `SEND` itself
      fails with `nerr=07` (`NERR_CLOSED`) and `tcp=03` (`F_RST`)
      (typical on real hardware, where the RST wins the race)

## Scenario B -- UDP (`-u`)

- [ ] Default 21-byte payload: `udp reply: len=21 data=SPRINTER UNETTEST
      UDP`, `udp echo ok`
- [ ] Sized payload at MTU boundary (1472 ok / 1473 NERR_PARAM)

## Scenario C -- dual channel (`-2`, MULTICHAN)

- [ ] Both `connect ...` lines, `request sent`
- [ ] Control/data interleave (`data stream continuous`, `control
      reply: ...`)
- [ ] Which ACK verdict was printed, and with what host settings.  Both
      `reply rode our ACK - SEND guard path exercised` and `not hit` are
      valid: the line reports whether the run entered the pend-guard
      state, not whether the DLL is correct.  `--lockstep` only controls
      when the server application replies, not when the host kernel
      ACKs, so `not hit` may be unavoidable from a given host.  Record
      it as "pend-guard branch not covered on hardware" rather than as a
      failure

## Scenario D -- passive open (`-l`, LISTEN/UNLISTEN)

- [ ] Peer 1 accepted/served/closed (`closed (re-arms LISTEN
      automatically)`)
- [ ] Peer 2 accepted/served/closed (re-arm confirmed)
- [ ] `unlisten done`

## Scenario E -- non-blocking SEND (`-a`, ASYNCSEND)

- [ ] `net.inet.tcp.doautorcvbuf=0` set before the run, and the peer
      logged `accepted socket rcvbuf=700` with no `WARNING` lines.
      Without this the run proves nothing, whatever the DSS side printed
- [ ] At least one `NERR_AGAIN` resume logged (`resumes needed: >=1`)
- [ ] Transfer settles (`request sent`), stall peer drains all 1200 bytes

Console output/screenshots:

Responder terminal output:

tcpdump excerpts (if captured):

Final result: PASS / FAIL / PARTIAL

New findings (describe, do not fix here):
