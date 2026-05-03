# Repository Guidelines

## Project Scope

This repository develops a network stack (driver + minimal protocol stack) and
a small package of utility programs for Sprinter DSS targeting the ISA-8
Ethernet card based on the Realtek RTL8019AS / DP8390 NIC. The repository must
also serve as a development kit so that other Sprinter DSS programs can reuse
the driver and stack to implement their own network exchange.

Hardware/software target:

```text
Sprinter
CPU: Z84C1516/Z84C15-class Z80 compatible CPU
OS: Sprinter DSS
language: Z80 asm
target card: ISA8 RTL8019AS Ethernet
MAME slot: -isa1 rtl8019as
default I/O base: 0x300
```

The authoritative staged development plan, register map, expected diagnostic
output and stage acceptance criteria live in
[`sprinter_rtl8019_soft.md`](sprinter_rtl8019_soft.md). Treat that file as the
project specification: every utility (HELLO, NICINFO, NICRAM, NICLB, NICTX,
NICRX, PING, UDPTEST, TFTP, NTP, WGET, FTP, ...) and the public driver API
(`rtl_probe`, `rtl_reset`, `rtl_init`, `rtl_read_prom`, `rtl_dma_read`,
`rtl_dma_write`, `rtl_send_frame`, `rtl_poll_rx`, `rtl_read_frame`, ...) are
defined there. Do not skip stages; each step must produce a verifiable
artifact before moving on.

Keep code and documentation focused on RTL8019AS/DP8390 register handling,
NE2000-style packet RAM access, IPv4/ARP/ICMP/UDP/TCP for Sprinter DSS, and
compatibility with both the MAME `rtl8019as` ISA slot and a future real
ISA-8 RTL8019AS card.

## Project Structure & Module Organization

This repository uses `src/include/` for shared include files, `src/lib/` for
reusable DSS assembly modules (driver and stack), and `src/apps/` for utility
entry points. Build outputs go to `build/`; distributable zip and floppy
images go to `distr/`. Package membership is controlled by
`tools/artifacts.sh`. User-facing documentation lives in `docs/`, batch and
host-side examples in `examples/`, configuration templates in `config/`.

Recommended `src/lib/` modules (see the spec for the full API surface):

```text
rtl8019.asm   low-level register access, init, tx, rx, remote DMA
eth.asm       Ethernet frame helpers
arp.asm       ARP request/reply and 1..4-entry ARP cache
ipv4.asm      IPv4 headers and checksum
icmp.asm      ICMP echo
udp.asm       UDP datagram send/receive
tcp.asm       minimal TCP (1 session early, 2 for FTP)
netcfg.asm    static IP/MAC/GW/DNS configuration
debug.asm     hex/register/stage-code diagnostics
```

The development kit role is explicit: each module must expose stable labels
and entry points that other Sprinter DSS programs can `INCLUDE` (or link
against) without dragging in app-specific state. Driver and stack functions
must return explicit status codes; never use hidden infinite waits.

The repository sits beside several reference projects. `../sprinter_wifi/`
contains the Sprinter Wi-Fi (ESP-AT) network package and is the closest
template for build/packaging/configuration conventions in this project. Other
sibling directories listed under "External reference sources" are read-only
references for platform details, executable formats, and assembler usage.

## Build, Test, and Development Commands

Use the project scripts for normal DSS package work (modeled after
`/Users/dmitry/dev/zx/sprinter/sprinter_wifi/network`):

```sh
make build      # assemble known DSS apps into build/*.EXE
make package    # create distr/sprinter-rtl8019a.zip
make image      # create distr/sprinter-rtl8019a.img FAT12 test floppy image
make clean      # remove generated outputs
```

The scripts must be tolerant while the project is being bootstrapped: apps
listed in `tools/artifacts.sh` are skipped with a warning until their
`src/apps/<name>.asm` entry point exists. Direct sjasmplus builds remain
useful when debugging a single source file:

```sh
sjasmplus src/apps/nicinfo.asm
sjasmplus src/apps/nicram.asm
```

Match the assembler choice to the existing Sprinter DSS toolchain. Confirm
the format and entry-point convention against the reference utilities under
`/Users/dmitry/dev/zx/sprinter/Estex-DSS`,
`/Users/dmitry/dev/zx/sprinter/utils`, and the Sprinter Wi-Fi network package
before introducing a new build path.

## Distribution Artifacts

`tools/artifacts.sh` is the single manifest used by `tools/build.sh`,
`tools/package.sh`, and `tools/image.sh`. When adding anything that must ship
with the network package, update this manifest in the same change.

Rules for future additions:

- New DSS utility: add its lowercase entry point name to `BUILD_APPS`; the
  source must be `src/apps/<name>.asm`, and scripts will build/copy
  `build/<UPPERCASE_NAME>.EXE`.
- New user documentation: add the relative path to `DIST_DOC_FILES`. Markdown
  is copied unchanged to the zip and renamed to an 8.3 `.TXT` name in the
  floppy image.
- New sample configuration: add the relative path to `DIST_CONFIG_FILES`.
  Never commit a real environment-bearing `NET.CFG`; ship only templates such
  as `config/NET.CFG.sample` (static `IP`, `NETMASK`, `GW`, `DNS`, `MAC`).
- New small required runtime asset: add it to `DIST_EXTRA_FILES`.
- If an artifact needs a subdirectory or a special 8.3 name inside the floppy
  image, update `tools/image.sh` together with `tools/artifacts.sh`.
- After changing artifact lists, run at least `make package` and, when mtools
  is available, `make image`.

## Coding Style & Naming Conventions

Preserve the existing Sprinter DSS assembly style. Assembly uses tabs for
instruction alignment, uppercase labels/constants, `EQU` constants, and
semicolon comments. Keep reusable routines in `src/lib/` and entry points in
`src/apps/<name>.asm`. Source-code comments are written in English. User
documentation under `docs/` is provided in both Russian and English.

For DSS assembly, avoid storing large zero-filled work buffers in `.EXE`
outputs. Assemblers such as `sjasmplus --raw` emit `DS ...,0` bytes into the
file, wasting disk space. Prefer runtime-only BSS-style labels placed after
the loaded image, for example after the driver's RX/TX buffer block end
label. Clear that runtime area at program start only when the code depends
on zeroed memory. Small state variables and required initialized data may
remain in the file.

Utilities that accept long command lines, including `WGET`, `UDPTEST`,
`TFTP`, `FTP`, and similar future tools, must use the full 512-byte DSS EXE
header with code file offset `0x0200`, load address `0x8100`, and entry
point `0x8100`. This keeps DSS command-line storage at `0x8080` from
overlapping the program entry code. The required header padding is allowed
and is not a runtime buffer; large runtime buffers still must live outside
the `.EXE` image.

Keep runtime memory maps explicit. When a utility needs command, URL,
packet, TCP/UDP receive, or configuration buffers, define them with `EQU` in
a BSS map instead of `DS ...,0`, and make sure the ranges do not overlap
while both values must stay alive. For buffers used as DSS file read/write
sources, keep them below the `0xC000` banking window unless the code
explicitly manages page switching. If a utility needs a large buffer,
allocate/use DSS paged memory and map it through available `WIN0`-`WIN3`
windows instead of embedding or assuming a large linear buffer in the
`.EXE`.

Driver buffer sizing baseline (see spec for the rationale):

```text
TX buffer: 1518 bytes (max Ethernet frame without FCS)
RX buffer: 1518 bytes
ARP cache: 1..4 entries
TCP sessions: 1 initially, 2 for FTP
```

If 1518-byte buffers do not fit a chosen DSS memory model, document the
alternative explicitly: read RX frames in chunks via remote DMA, use TCP
MSS 536, and write HTTP/TFTP payloads to disk in blocks.

Keep optional protocol modes out of common includes. Code that only some
utilities need (for example a multi-session TCP path used by FTP, or full
DHCP/DNS) must live in a separate library include or be guarded by
assembly-time conditionals. Simple clients such as `PING`, `NTP`, `UDPTEST`,
`TFTP`, and `WGET` should not grow from unused FTP/server helpers.

## Diagnostic Output Conventions

All utilities print short stage codes so a problem can be diagnosed from a
MAME screenshot without an attached debugger. Required format, taken from
the spec:

- print utility name and version on the first line;
- every successful step is `[N...]` (or stage-specific letter such as
  `[R...]`, `[L...]`, `[T...]`, `[X...]`, `[P...]`, `[U...]`, `[F...]`,
  `[W...]`, `[NTP...]`, `[FTP...]`);
- every error is `[E...]`;
- print expected vs actual values on mismatch;
- on timeout, print stage code, NIC registers (`CR ISR DCR RCR TCR IMR
  PSTART PSTOP BNRY CURR`), TX/RX counters, and target IP/MAC/port if
  applicable;
- never clear the screen after an error;
- never wait without an explicit timeout;
- finish with `RESULT OK` or `RESULT FAIL`.

## Exit Status Guidelines

DSS utilities that can reasonably be used from batch scripts must return a
meaningful status through `DSS_EXIT`. Use `B=0` for success. Prefer these
common non-zero codes unless a program documents a stronger reason to
differ:

- `1` - invalid command line or usage error.
- `2` - RTL8019AS hardware was not detected at the configured I/O base.
- `3` - NIC/network communication error: remote DMA timeout, TX/RX timeout,
  ARP/ICMP/UDP/TCP timeout, unreachable host, or unexpected NIC state.
- `4` - configuration error, for example missing or invalid `NET.CFG`.

Document utility-specific exit status behavior in `docs/USAGE.md` whenever a
new automation-friendly program is added or changed.

## Debugging Environment

Primary debugging uses the MAME Sprinter build at
`/Users/dmitry/dev/zx/sprinter/mame` with the ISA slot
`-isa1 rtl8019as`. The reference launch script is
`/Users/dmitry/dev/zx/sprinter/mame/run_sprinter_rtl8019as.sh`, and
project-level notes live in
`/Users/dmitry/dev/zx/sprinter/mame/MAME_RTL8019AS.md` and
`/Users/dmitry/dev/zx/sprinter/mame/mame_sp_rtl8019as.md`. Each development
stage from the spec is run inside MAME; the user sends a screenshot or log,
the agent analyzes, fixes code or MAME glue, and the same stage is repeated
before moving on.

MAME is not a source of absolute truth. When a register, PROM byte, or
remote DMA result looks wrong:

1. Inspect MAME's RTL8019AS device implementation under the source tree
   (`find /Users/dmitry/dev/zx/sprinter/mame -name "*8019*"`) and check the
   exact behavior emulated for the failing register, page, or operation.
2. Cross-check against authoritative open documentation for RTL8019AS and
   DP8390 (Realtek datasheet, National Semiconductor DP8390 datasheet,
   public NE2000/NE2000+ programmer's manuals, Crynwr packet driver notes -
   used as reference only, not as imported code).
3. If the spec, MAME, and the datasheets disagree, prefer the datasheet for
   real-hardware behavior, file an emulator gap, and either add a fallback
   in the driver or argue for a MAME fix with a citation.
4. Update both `sprinter_rtl8019_soft.md` and the MAME-side notes when the
   discovered behavior changes the model (PROM layout, reset semantics,
   I/O base decoding).

When the physical RTL8019AS card becomes available, switch to field testing
on the real Sprinter. Until the driver is stable in MAME, do not declare it
ready for real hardware. For real-hardware bring-up the spec calls out:

- precise ISA8 address decoding;
- confirmed reset port behavior at `BASE+0x1f`;
- accurate PROM/EEPROM layout;
- IRQ line verification;
- 5V level and bus timing checks.

## Driver / Stack Constraints

These constraints are non-negotiable until the spec is updated:

- 8-bit data path only: `DCR.WTS = 0`, recommended `DCR = 0x48`. Never enable
  16-bit word transfer mode on this ISA8 card.
- Default I/O base `0x300`; a probe path must be allowed for alternative
  bases later, but stage-1 utilities may hardcode `0x300`.
- Polling driver first; do not depend on IRQ until early stages succeed.
- Page select via `CR` bits 6..7 with explicit constants from the spec
  (`0x21`, `0x22`, `0x61`, `0xa1`, `0xe1`, ...).
- NE2000-style packet RAM layout: `TPSR=0x40`, `PSTART=0x46`, `PSTOP=0x80`,
  `BNRY=0x46`, `CURR=0x47`, page size 256 bytes.
- Pad TX frames shorter than 60 bytes (without FCS) up to 60 bytes.
- All waits (reset, RDC, TX complete, RX, ARP, UDP reply, TCP retransmit)
  must have explicit timeouts and emit diagnostic output on expiry.

## Forbidden Practices

- Do not import x86 packet drivers as binaries; they target a different CPU
  and architecture. Public NE2000/DP8390 descriptions may be consulted as
  references only.
- Do not start with DHCP, DNS, full TCP retransmit, or FTP before the early
  diagnostic stages (`HELLO` -> `NICINFO` -> `NICRAM` -> `NICLB` -> `NICTX`
  -> `NICRX`) are passing.
- Do not introduce hidden infinite waits anywhere in the driver or stack.
- Do not enable 16-bit word DMA mode.

## Testing Guidelines

No automated test suite is present. For every touched DSS assembly source,
assemble it and smoke-test the affected stage in MAME against the expected
output from the spec. When the physical card is available, repeat the same
stage on real hardware and record any divergence. For any change that
touches the driver register sequence, re-run at minimum `NICINFO.EXE` and
`NICRAM.EXE`, since they are the canonical regression checks.

Host-side helpers are welcome and belong in `examples/` (batch files for
DSS, plus shell or Python scripts for the host side, for example a UDP echo
responder used by `UDPTEST.EXE` or a small TFTP server for `TFTP.EXE`).

## Acceptance Criteria

The early driver is considered ready when:

- `NICINFO.EXE` reliably detects the card and prints `RTL ID=Pp` and the
  PROM MAC;
- `NICRAM.EXE` confirms remote DMA round-trips at 16, 64, 256, and 1536
  bytes;
- `NICLB.EXE` confirms the TX path (and, when MAME supports it, the
  loopback RX path);
- `PING.EXE` receives ICMP echo replies from a local host or router;
- every error path prints stage code and NIC registers;
- there are no infinite waits without diagnostic output.

The minimal network kit is considered ready when:

- `PING.EXE` works over IPv4;
- `UDPTEST.EXE` receives an echo response;
- `TFTP.EXE` downloads a file;
- `NTP.EXE` retrieves and prints time;
- `WGET.EXE` downloads plain HTTP files of 2 KB, 24 KB, and 56 KB;
- `FTP.EXE` performs passive mode with both control and data TCP sessions;
- every failure can be diagnosed from a MAME screenshot alone.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects: `Add NICINFO PROM read`, `Fix RDC
timeout in rtl_dma_read`, `Document NICLB stage`. Pull requests should
describe scope (driver, stack, app, docs, MAME notes), list manual tests
and build commands run, link the relevant stage in
`sprinter_rtl8019_soft.md`, and attach screenshots or logs that demonstrate
the affected stage's expected output.

## Security & Configuration Tips

Do not commit local network credentials, real `NET.CFG` files,
machine-specific IDE state, or temporary build outputs. When utility
behavior depends on a specific RTL8019AS revision or MAME build, document
that dependency in the relevant `docs/*.md` file.

## External reference sources

Consult the following local sibling repositories/directories for platform
details, executable formats, assembler usage, and prior-art network
implementations. Treat them as reference material only; this repository
remains the source of truth for changes you make here.

- `/Users/dmitry/dev/zx/sprinter/sprinter_bios`
- `/Users/dmitry/dev/zx/sprinter/Estex-DSS`
- `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
- `/Users/dmitry/dev/zx/sprinter/sources/tasm_071/TASM`
- `/Users/dmitry/dev/zx/sprinter/sources/fformat/src/fformat_v113`
- `/Users/dmitry/dev/zx/sprinter/sources/fm/FM-SRC/FM`
- `/Users/dmitry/dev/zx/sprinter/sdcc-sprinter-sdk`
- `/Users/dmitry/dev/zx/sprinter/utils`
- `/Users/dmitry/dev/zx/sprinter/sprinter_wifi` (ESPKit, SprinterESP, network -
  closest template for build/packaging/config and diagnostic style)
- `/Users/dmitry/dev/zx/sprinter/sources/bc-term`
- `/Users/dmitry/dev/zx/sprinter/mame` and
  `/Users/dmitry/dev/zx/sprinter/mame_esp` (MAME source, RTL8019AS device
  notes, run scripts)
