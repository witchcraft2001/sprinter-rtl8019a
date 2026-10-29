# UNETRTL 0.4.7: independent SEND work quantum

Candidate DLL: 18148 bytes, SHA-256
`1ad3c109148047975bcd6439adbd3b1382273fc23be234e9b47c4f59033b8108`.
Baseline 0.4.6: SHA-256
`ce188ae6df65f9548530fb9862af7965388115c0e3cb63704c70a39e6d8f6a8b`.
No commit or tag was created.

## Implementation

Nonzero SENDSLICE enables a separate work limit: one wire send or one
receive step per public call. The receive step paces once with ISA closed,
then polls for one packet. The continuation stores the instruction address
inside the DLL, including deferred retransmits, probes and MSS transitions.
The caller retains its original buffer; DE remains the acknowledged prefix.
Retry/persist counters survive yields. Blocking SEND, UDP SEND, the shared
ABI/capabilities, MSS, receive queues and page allocation are unchanged.
SENDSLICE retains its option value/minimum; AGAIN has an additional cause.
Driver TX/DMA/overflow-recovery waits retain their existing bounds.

The host observer now exposes CPU cycles as well as logical delay ticks.
New actual-DLL checks cover first-TX yields, RECV/STATUS between resumes,
either owner channel and relocation into WIN1/WIN2. Existing response,
long PUT, retransmit, persist and FIN vectors now allow additional resumes
and continue to check the completed stream and terminal outcomes.

## Host and distribution checks

`make test-host package image` passed, including 585 actual-EXE checks
(220 DLL cases), plus Python checks. The final repeat passed as well and
reproduced the same DLL digest. Logs: `/tmp/send-quantum-final-gate.log`.
All 32 ZIP/FAT12 files were compared byte for byte; 8.3 names and DOS CRLF
were checked. The frozen `unet.inc` mirror still matches sprinter_wifi.

## MAME ordinary and load results

MAME SHA-256:
`cf8a901ccd9dec075ead20dfbff1cf6f34a7b0d2d8f43a0823d090a0ce3c90ef`.
All runs use native speed, audio Off, independent guests and newly prepared
input sets. Original report input sets and sibling sources were preserved.
Times below include the dispatcher and DLL; they are not isolated CPU time.

| EXE | Scenario | HOST SEND max ms | JOIN max ms | WATCH max ms | Functional |
| --- | --- | ---: | ---: | ---: | --- |
| 0b902030... | original DIRECT, ordinary | 5.144286 | 5.208000 | -- | PASS |
| 5518db11... | corrected original MQTT, ordinary | 7.280571 | 5.542857 | 5.203714 | PASS |
| 3088c4b0... | final DIRECT, ordinary | 4.788286 | 3.872857 | -- | PASS |
| 3088c4b0... | final MQTT, ordinary | 6.821143 | 5.380286 | 6.638857 | PASS |
| 3088c4b0... | final DIRECT, load | 5.177143 | 5.867143 | -- | PASS |
| 3088c4b0... | final MQTT, load | 6.641143 | 5.820000 | 6.600571 | PASS |
| 3088c4b0... | final DIRECT, faults | 4.645714 | 3.875714 | -- | PASS |

The load windows last 600.84 seconds per DIRECT guest and 601.65 seconds
per MQTT guest. Across the complete load runs, 39093 SEND calls were
recorded; none exceeded 10 ms. Runs include game completion, chat, rematch,
resign and clean DSS exits. MQTT has HOST/JOIN/WATCH plus seven PC WATCH.

The independent 100 ms physical-input-to-PRESENT requirement is still open.
For example, MQTT load HOST has 292 reaction samples, maximum 491.923672 ms,
p95 163.096528 ms, with 112 samples above 100 ms. These include the complete
scenario, not just its steady-load window. No attribution of these overruns
to the DLL is made. The load report records pcap queue drops HOST/JOIN/WATCH
37559/38259/35020; no loss was deliberately injected in that load run.

## Open acceptance observations

The first candidate MQTT faults run stopped waiting for FIRE after
`real_NERR_AGAIN_input_and_menu_service`. Earlier reset, broker-restart,
Ethernet-loss and ACK-stall checks passed. Its maximum SEND remained under
7 ms. A separate frozen-input control using baseline 0.4.6 passed the full
MQTT faults scenario; baseline SEND maxima reached 93.293429 ms. Thus the
candidate failure is retained as an open result, not dismissed as an
established pre-existing failure. An unchanged repeat also stopped at the same FIRE wait. Both candidate
runs are failures; full MQTT faults acceptance remains open. This is a
material functional risk despite passing ordinary/load and host tests.

The raw observer reaction coverage is arrows and WATCH V; input.tsv also
retains physical FIRE commands. A complete per-key reaction claim is not made.

Trace scans found no changed pending channel/pointer/length/bytes or API
teardown while pending. Some continuation intervals contain STATUS without
RECV; the strict every-continuation RECV/STATUS criterion is therefore not
fully met by these captured clients. Dispatcher CF=1 continuation was not
encountered in these MAME runs. Real hardware and other audio profiles were
not tested. This record does not certify all S08 performance/coverage items.

## Local evidence and reproduction

Machine-readable summaries, every ABI maximum, reaction summaries, call-file
hashes and continuation observations are in `build/send-quantum-summary.json`.
Raw evidence remains in ignored build outputs, not Git:

- `build/s08-quantum/build/s08/20261028-112104-rtl-inputs/`
- `build/s08-quantum-old-direct/build/s08/20261028-114019-rtl-inputs/`
- `build/s08-quantum-old-mqtt/build/s08/20261028-114019-rtl-inputs/`
- `build/s08-quantum-baseline/build/s08/20261028-141255-rtl-inputs/`

Each private root contains frozen coordinator/observer tools, the saved EXE,
symbols, candidate/baseline DLL, individual images and hash manifests.
For example, from the repository root, with pcap access:

```sh
BSHIP_ROOT="$PWD/build/s08-quantum" PYTHONDONTWRITEBYTECODE=1 \
python3 build/s08-quantum/tools/s08_emulator.py run \
  --card rtl --suite load --profiles off --transports direct mqtt --jobs 2 \
  --inputs build/s08-quantum/build/s08/20261028-112104-rtl-inputs
```

Use `--suite perf` for ordinary tests and `--suite faults` for the fault
matrix. Use the corresponding private root/input set for the earlier EXEs
or baseline. Failed sandbox/preflight attempts are retained separately and
are not counted as guest acceptance runs.

## MQTT FIRE failure: diagnosis

A third candidate faults run used the same EXE and DLL with a private,
read-only opcode observer restricted to FIRE (`cl_cmd`, B=0x11). It again
stopped at the FIRE wait. At MAME 292.021813619 s JOIN handled Enter with
SEND pending. At 292.022031333 s `cl_cmd` received FIRE with `cl_c_on=2`,
`cl_s_on=0`, `cl_status=1` (CS_READY), and `cl_role=0`. The first guard in
`cl_cmd` consequently returns CF=1: another changing SBP command was sent
and still awaited its response. At 292.044090762 s the guest snapshot shows
`ui_error_code=2`, `source_status=5`, `source_command_pending=0`, and
`st_guard_trips=0`. The coordinator then timed out waiting for HOST revision
change. The earlier two runs show the same Enter -> error 2 -> cleared
command sequence; this run identifies the specific guard.

The scenario sends a CHAT while the link is blocked, reopens it, and waits
for HOST to observe that CHAT before triggering FIRE. HOST observation does
not establish that JOIN has received the response and cleared `cl_c_on`.
`direct_queue_command` treats CF=1 as a fatal busy outcome, clears the FIRE
request, and does not retry it. Faster SEND continuations change the timing
and expose this application-level race; the baseline passing once does not
prove that the same interleaving was safe with 0.4.6. The measurements do
not by themselves establish which SBP response occupied the slot.

A real fix belongs in Battleship's source-command scheduler: retain a FIRE
intent while a previous changing command or SYNC is pending, dispatch it once
when the client slot becomes available, and distinguish queued from accepted
so it cannot be sent twice. Preserve its original game/revision/cell; a
stale revision must still follow the existing protocol instead of silently
rewriting the request. Cover both DIRECT and MQTT, CHAT_ACK/SYNC delays,
reconnect, cancellation, and repeated FIRE, then rerun the faults suite.
The DLL cannot implement that queue: it sees opaque TCP bytes and has no
access to the application's command identity, response or revision. Delaying
SEND until this race disappears would reintroduce long blocking calls without
ensuring that an application-level response has been processed.

The diagnostic observer, frozen inputs, call/state/input traces and result
are local under `build/s08-quantum-diagnose/build/s08/20261028-160313-rtl-inputs/`.
The preceding diagnostic run wrote every command event and stopped earlier
at the late CHAT assertion; its heavier observer may perturb timing and it
is not counted as reproduction of the FIRE failure. Neither diagnostic run
changed the EXE or DLL; no game source or production DLL was modified for
this diagnosis.
