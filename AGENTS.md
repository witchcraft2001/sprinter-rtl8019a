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
reusable DSS assembly modules (driver and stack), `src/dll/` for libman 1.3 /
L1 loadable libraries, and `src/apps/` for utility entry points. Build outputs go to `build/`; distributable zip and floppy
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

**Mandatory: every code-changing iteration must end with `make package image`,
not just `make build`.** The MAME test stand boots from
`distr/sprinter-rtl8019a.img`, so a fresh `.EXE` in `build/` is invisible to
the next test run until the floppy image is rebuilt. Treat the image as the
deliverable that proves the change actually reaches the target. Use
`make build` alone only for quick "does it assemble?" checks; before asking
the user to retest in MAME (or before announcing a fix as ready), run
`make package image` and confirm both `distr/*.zip` and `distr/*.img` are
regenerated.

The scripts must be tolerant while the project is being bootstrapped: apps
listed in `tools/artifacts.sh` are skipped with a warning until their
`src/apps/<name>.asm` entry point exists. Direct sjasmplus builds remain
useful when debugging a single source file:

```sh
sjasmplus -I src/include -I src/lib --raw=build/HELLO.EXE src/apps/hello.asm
sjasmplus -I src/include -I src/lib --raw=build/NICINFO.EXE src/apps/nicinfo.asm
```

Assembler is locked to **sjasmplus** for this project (matches
`sprinter_wifi/network` and the bootstrap scripts under `tools/`). Other
assemblers in the reference tree (TASM, etc.) may be useful for reading
existing utilities but must not be introduced into the build path.

## Distribution Artifacts

`tools/artifacts.sh` is the single manifest used by `tools/build.sh`,
`tools/package.sh`, and `tools/image.sh`. When adding anything that must ship
with the network package, update this manifest in the same change.

### Filesystem & 8.3 naming constraints (mandatory)

The deployment target on real Sprinter hardware is **FAT16** (hard disk) and
the test floppy image is **FAT12** — both use classic DOS 8.3 short
filenames with no LFN support. **Every file shipped in `distr/` (both the
zip and the floppy image) must conform to 8.3, with no exceptions.** The
zip is unpacked directly onto the target FAT volume, so any non-8.3 name
in the zip will be silently truncated/mangled by the DSS file system or
refused outright. There is no "host-facing" loophole.

Concrete rules:

- **Base name** ≤ 8 ASCII characters; **extension** ≤ 3 ASCII characters;
  exactly one `.` separator. No spaces.
- **Charset:** uppercase A–Z, digits 0–9, and the conservative set
  `! # $ & ( ) - @ ^ _ \` { } ~`. Do not use lowercase, spaces, `+ , ; = [ ]`,
  or any non-ASCII characters in shipped names.
- **Single canonical name across zip and image.** A given artifact has
  exactly one 8.3 name; both `package.sh` and `image.sh` ship it under
  that name. Do not maintain a "long" name in the zip and a separate
  "short" name in the image — pick the 8.3 form once and use it
  everywhere shipped.
- **Utility EXE names:** the lowercase entry-point name in `BUILD_APPS` plus
  the auto-uppercased `.EXE` extension must fit 8.3 (`HELLO.EXE`,
  `NICINFO.EXE`, `UDPTEST.EXE`, ...). New entries must be ≤ 8 characters.
- **Documentation files:** `tools/image.sh` and `tools/package.sh` remap
  `*.md` to `*.TXT` for both the image and the zip. The remapped 8.3 form
  must be unique and fit the limits — `docs/USAGE.md` → `USAGE.TXT`,
  `docs/NETPROBE.md` → `NETPROBE.TXT`. `docs/MAME_NETWORK.md` is over the
  8-character base limit on purpose: it is developer-only and stays out
  of `DIST_DOC_FILES`.
- **Config templates** ship as 8.3 too. The active config is `NET.CFG`;
  the sample template ships as `NETSMPL.CFG`, and the user installs it
  with `REN NETSMPL.CFG NET.CFG`. The source-tree file at
  `config/NETSMPL.CFG` keeps the same 8.3 name for consistency, even
  though source-tree files are not strictly bound by 8.3.
- **Examples and extras:** `examples/CONNECT.BAT`, `examples/UDPECHO.PY`,
  etc. — base name ≤ 8 chars, uppercase, extension ≤ 3 chars (`.BAT`,
  `.PY`, `.TXT`, ...). Long descriptive names belong in comments inside
  the file, not in the file name.
- **Subdirectories on the image** also follow 8.3 (≤ 8 chars, uppercase).
  Prefer keeping the image flat; add a subdirectory only when it is
  genuinely needed.
- **Verification:** after changing any shipped name, run `make package`
  and `make image`, then `unzip -l distr/<name>.zip` and
  `mdir -i distr/<name>.img ::` to confirm the actual names match in
  both artifacts.
- **Line endings.** Files on the FAT volume that are text by nature
  (`*.TXT`, `*.CFG`, `*.BAT`, `*.INI`, `*.INF`, and any `*.md` remapped
  to `*.TXT`) must use DOS **CRLF** line endings. Without CR the DSS
  text viewers render a stray glyph or run lines together. Source-tree
  files keep native LF for editing convenience; `tools/package.sh` and
  `tools/image.sh` perform LF→CRLF conversion at packaging time
  (idempotent for files that already use CRLF). Binaries (`*.EXE`,
  `*.COM`, `*.BIN`, `*.IMG`, ...) are copied byte-for-byte without
  conversion.
- **Character encoding.** Shipped text files (every text artifact in
  `DIST_*` arrays) must be **7-bit ASCII**. The DSS text viewer renders
  through CP866; UTF-8 multi-byte characters appear as mojibake (e.g.
  the em-dash `—` shows up as `тАФ`). `tools/package.sh` and
  `tools/image.sh` fail the build with a clear error if a shipped text
  file contains any byte ≥ 0x80. Use ASCII equivalents (`--` for em-dash,
  `...` for ellipsis, etc.) or add an explicit UTF-8 → CP866 transcoding
  step (and document it) before introducing localized text.

Files that live only in the source tree and are not in any `DIST_*`
array (the spec, `AGENTS.md`/`CLAUDE.md`, `docs/MAME_NETWORK.md`,
`tools/dev/*`, `Makefile`, `*.asm`, `*.inc`) are free of 8.3 constraints.
As a rule of thumb: if a path appears in any `DIST_*` list, it is
8.3-bound — either by its source-tree name, or by an explicit remap in
both `tools/package.sh` and `tools/image.sh`.

Rules for future additions:

- New DSS utility: add its lowercase entry point name to `BUILD_APPS`; the
  source must be `src/apps/<name>.asm`, and scripts will build/copy
  `build/<UPPERCASE_NAME>.EXE`.
- New user documentation: add the relative path to `DIST_DOC_FILES`. Markdown
  is copied unchanged to the zip and renamed to an 8.3 `.TXT` name in the
  floppy image.
- New sample configuration: add the relative path to `DIST_CONFIG_FILES`.
  Never commit a real environment-bearing `NET.CFG`; ship only templates
  such as `config/NET.CFG.sample`. Locked schema for this project:
  `RTL_IOBASE`, `RTL_IRQ`, `RTL_MAC` (optional override of PROM MAC),
  `IP`, `NETMASK`, `GATEWAY`, `DNS1`, `DNS2`, `TZ`, `NTP`. Lines starting
  with `#` are comments; unknown keys are ignored.
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

**Mandatory rule: zero-filled work buffers MUST NOT live inside the
`.EXE` image.** `sjasmplus --raw` emits `DS N,0` and similar zero-filled
storage as bytes in the output, which inflates disk size, slows DSS load,
and consumes floppy capacity for nothing. Even small buffers (a few
bytes) follow this rule -- the cost of a couple of `LD (label),0`
instructions at startup is far cheaper than zero bytes shipped on every
copy of the program. Concretely:

- Small/medium runtime buffers (anything that the program writes before
  it reads, e.g. DMA work buffers, parser scratch, ARGV, response
  buffers): declare them with `EQU` at fixed addresses inside the
  directly-addressable Z80 RAM (above the loaded image, below the
  `0xC000` banking window). Initialize to zero at program start ONLY if
  the code actually depends on the initial value; otherwise leave them
  uninitialized and let normal "write before read" handle it.
- Large buffers (more than a few KB, or anything that won't fit between
  end-of-image and `0xC000`): allocate DSS paged memory via the
  appropriate DSS syscall and map it through `WIN0`-`WIN3`.
- Initialized data (lookup tables, message strings, default values that
  the program reads BEFORE writing) stays in the `.EXE` as DB/DW. This
  rule is about *zero-filled* uninitialized buffers only.

**Exception: `src/dll/*.asm`.** A libman DLL is relocated into window 1
(`0x4000`) or window 2 (`0x8000`), so the absolute map below is unusable
-- `0xA000..0xAFFF` is *inside* window 2, and libman packs several DLLs
into one 16 KB page, so memory past the declared image length may belong
to another library. DSS paged memory is no escape either, because paged
blocks map through `WIN0`-`WIN3` and `WIN3` is the ISA window whenever
the driver is active. A DLL therefore declares all of its BSS as
`DS n,0` **inside** the image and points `memmap.inc` at it (see
"Parameterized BSS" below). This exception applies to `src/dll/` only;
every `.EXE` still follows the rule above.

Project-wide runtime memory map for shared library buffers lives in
`src/include/memmap.inc`. Each library exposes a single `EQU` for its
buffer base and another for the size; per-app private buffers start at
`APP_BSS_BASE` (also in `memmap.inc`). When you add a new library
buffer, place it in `memmap.inc` -- do not pick an ad-hoc address in the
library file.

**Parameterized BSS.** Every address in `memmap.inc` is written as
`<region base> + offset`, and the bases (`LIBBSS_BASE`, `CMDL_BSS_BASE`,
`RESOLVE_BSS_BASE`, `TCP_BSS_BASE`, `UDP_BSS_BASE`, `ICMP_BSS_BASE`) get
their historical absolute values unless `LIBBSS_CUSTOM` is defined. A DLL
defines `LIBBSS_CUSTOM` plus its own bases before including `memmap.inc`.
Two rules follow:

- **Sizes must be literals, never a difference of two addresses.** In a
  relocatable image both operands are relocated, so `EQU 0xAA26 - 0xAA00`
  silently becomes wrong. Write `EQU 38`.
- **The regression gate for any `memmap.inc` change is byte identity.**
  Rebuild and `cmp` every `build/*.EXE` against a pre-change copy; the
  default branch must reproduce the old map exactly.

**`LIB_NO_CONSOLE`.** A library linked into a DLL must never print to the
consumer's screen nor terminate the host process. The few library paths
that call `DSS_PCHARS` or `DSS_EXIT` (`RTL.INIT_BASE`'s fallback warning,
`NETENV.REQUIRE_IP`/`REQUIRE_MAC`, `CMDL.DIE_USAGE`, `UTIL.EXIT*`) are
wrapped in `IFNDEF LIB_NO_CONSOLE`, which `src/dll/*.asm` defines. This is
compile-time rather than a runtime flag so the message strings are deleted
too, and so a forgotten flag write cannot paint over a consumer's screen.

Required initialized data (default values, banner strings, lookup
tables) stays in the `.EXE` as `DB/DW`. The rule applies to
*zero-filled* buffers only.

DSS EXE header conventions used in this project (locked, taken from the
`sprinter_wifi/network` toolchain):

- **Small utilities (≤ 16 KB code+data, header inside command-line area).**
  `ORG 0x8080`. The first 128 bytes are the DSS EXE header (`"EXE"`, version
  byte, flags, entry, entry, stack-top, padding to 0x80). Entry point is
  placed at `0x8100`. Stack top label is also at `0x8100`. Header layout
  matches `sprinter_wifi/network/src/apps/ping.asm:21-33`.

- **Large utilities (> 16 KB code+data).** `ORG 0x4100` for the header,
  entry point at `0x4200`, and the header stack field set to `0x8000`.
  This moves the image out of the `0x8000..0xBFFF` window and gives ~32 KB
  linear room before the `0xC000` banking window kicks in. Required for
  `WGET`, `TFTP`, `FTP` and any future utility that pulls in large library
  code.

  **The header is not loaded into memory.** DSS reads the first `hdr_size`
  bytes of the file (the `DW` at header offset `0x004`) and loads what
  follows at the code `ORG`; the header's own `ORG` only fixes its position
  in the FILE, immediately ahead of the code. Sibling
  `sprinter_wifi/network` proves it -- its large apps put the header at
  `0x3F00`, below WIN1 entirely, with code at `0x4100`. So a large utility
  that runs out of room below the `0x7F80` ceiling can move its whole image
  one page down (`ORG 0x4000` for the header, `ORG 0x4100` for the code,
  `hdr_size` unchanged at `0x0100`) and gain 256 bytes. `TELNET.EXE` uses
  that layout; the others keep `0x4100`/`0x4200` until they need it.

  **The header is not loaded into memory.** DSS reads the first `hdr_size`
  bytes of the file (the `DW` at header offset `0x004`) and loads what
  follows at the code `ORG`; the header's own `ORG` only fixes its position
  in the FILE, immediately ahead of the code. Sibling
  `sprinter_wifi/network` proves it -- its large apps put the header at
  `0x3F00`, below WIN1 entirely, with code at `0x4100`. So a large utility
  that runs out of room below the `0x7F80` ceiling can move its whole image
  one page down (`ORG 0x4000` for the header, `ORG 0x4100` for the code,
  `hdr_size` unchanged at `0x0100`) and gain 256 bytes. `TELNET.EXE` uses
  that layout; the others keep `0x4100`/`0x4200` until they need it.

  **Such a utility MUST claim WIN2 before it touches any BSS**, because
  DSS `EXEC` maps only the windows the image itself occupies, starting at
  the window of the load address: an image of one page loaded at `0x4200`
  owns WIN1 only, and `0x8000..0xBFFF` still holds the *caller's* page.
  Writing BSS (`LIBBSS_BASE`, `APP_BSS_BASE`, per-library regions) or
  running the stack there corrupts the launcher -- the Sprinter File
  Manager runs its own code at `0x8000` and hangs as soon as the utility
  returns. The first instruction of `START` is therefore

  ```
  START
  	CLAIM_RUNTIME_PAGE	; WIN2 is the caller's page until this runs
  	LD	(CMDL_SOURCE_PTR),IX
  ```

  which allocates one page, maps it over WIN2 (`src/lib/win2page.asm`,
  add `INCLUDE "win2page.asm"` to the library list) and sets
  `SP = RT_STACK_TOP`. DSS frees the block and restores SLOT2 at `EXIT`,
  so there is no teardown call. Every app BSS map must then stay clear of
  the space below `RT_STACK_TOP`; assert it.

  **The stack must never be left in WIN1** (`0x4000..0x7FFF`) across DSS
  console output. Printing scrolls when the cursor is on the last row, and
  `Dss.Scroll` -> `BIOS.WIN_MOVE` maps the video page over WIN1 and then
  restores SLOT1 with `POP AF / OUT (SLOT1),A` -- the `POP` runs while the
  video page is still mapped (`sprinter_bios` `FUNC_LOW_PRINT.ASM`,
  `WIN_COPY_WIN1` / `WIN_RESTORE`). A WIN1 stack makes that byte come out
  of video RAM, SLOT1 is restored to a random page, and the machine dies
  inside the print. Only the syscalls of `CLAIM_RUNTIME_PAGE` itself, which
  print nothing, may run on the WIN1 entry stack.

**Choosing between the two variants is driven by command-line needs first,
size only as a tie-breaker.** The small variant occupies `0x8080..0x80FF`
and is reserved for short/no-argument utilities. The large variant places
the header at `0x4100..0x41FF`, providing the linear room required by
multi-token clients. Neither address defines the PSP location; DSS chooses
that location at load time.

For both variants, DSS passes the actual PSP/length-prefixed command-line
pointer in `IX` at entry (`[IX+0]` is the length). Any app accepting arguments
must save `IX` as the very first instruction at `START`, before every `CALL`
or `RST DSS`, and parse through that saved pointer. Never derive the PSP from
`ORG`, the entry address, `Entry-0x80`, `0x8080`, or `0x4180`.

Mandatory rule:

- Use the small variant (`ORG 0x8080`) ONLY for utilities that do not
  expect a long command-line argument list. Acceptable for: `HELLO`,
  `NICINFO`, `NICRAM`, `NICLB`, `NICTX`, `NICRX`, `NETCFG` show/set with
  short args, `ARP` show, `NICDUMP` and similar diagnostics that take no
  arguments or only one short flag/value.
- Use the large variant (`ORG 0x4100`, entry `0x4200`, SP `0xBFFF`) for
  any utility that parses URLs, host names, file paths, multi-token
  arguments or otherwise relies on the full DSS command-line buffer passed
  through `IX`. Required for: `WGET`, `TFTP`, `FTP`, `NTP` (with server arg),
  `PING` (with host arg), `UDPTEST` (host/port/payload), and any future
  tool of the same shape.

If a utility starts as a no-arg diagnostic (small variant) and later grows
command-line arguments, migrate it to the large variant in the same change
that adds the arguments — do not try to keep the small header by squeezing
arguments into a shorter buffer.

**Exception: DLL consumers.** A program that loads a libman DLL must own
exactly ONE 16 KB window, because the DLL needs the other one. The large
variant straddles both (code at `0x4100` in window 1, `SP=0xBFFF` in
window 2), so a DLL consumer uses the SMALL variant even when it takes
arguments: `ORG 0x8080`, entry `0x8100`, stack and buffers placed after
the image with `ASSERT STACK_TOP <= 0xC000`, and the DLL loaded into
window 1. `src/apps/unettest.asm` is the reference. This is a property of
being a DLL consumer, not a general licence to squeeze arguments into the
small header.

**The UNET ABI is a mirror, not a local file.** `src/include/unet.inc` is
byte-identical to the frozen contract in the sibling `sprinter_wifi`
project; both backends must compile against the same function numbers and
error codes. `tools/build.sh` enforces this with `cmp` whenever the
sibling is checked out. To change the ABI, change it there first, then
re-copy — never edit the local copy.

The required header padding is allowed and is not a runtime buffer; large
runtime buffers still must live outside the `.EXE` image (BSS-style labels
after the loaded image, see paragraph above).

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

### MAME Network Setup

Stages 0..3 (`HELLO`, `NICINFO`, `NICRAM`, `NICLB`) do not require a host
network backend and can be run with `-networkprovider none`. Stages 4+
(`NICTX`, `NICRX`, `PING`, `UDPTEST`, `TFTP`, `NTP`, `WGET`, `FTP`)
require a working pcap-based backend on macOS.

The full developer workflow — provider selection, `/dev/bpf` permissions on
macOS, host-interface guidance, per-stage verification recipes (tcpdump
filter for `NICTX`, scapy generator for `NICRX`, IP plan for `PING/UDP/TCP`),
and acceptance criteria for the network environment — lives in
[`docs/MAME_NETWORK.md`](docs/MAME_NETWORK.md). That document is
developer-only and must NOT be added to `DIST_DOC_FILES`.

`slirp` is not available in the current MAME build for macOS; do not write
scripts that assume it. TAP/bridge helpers are an explicit non-baseline:
add only if pcap proves unstable.

## Driver / Stack Constraints

These constraints are non-negotiable until the spec is updated:

- 8-bit data path only: `DCR.WTS = 0`, mandatory `DCR = 0x48` after
  `device_reset` for normal operation. Never enable 16-bit word transfer
  mode on this ISA8 card. MAME's `device_reset` sets `DCR = 0x04`; the
  driver must rewrite `DCR` to `0x48` as part of its init sequence and
  never rely on the post-reset default. **Exception: loopback testing
  (NICLB / TCR-LB modes) requires `DCR.LS = 0`, so use `DCR = 0x40`
  (the same as `0x48` minus the LS bit) only inside the loopback
  configuration. MAME's `LOOPBACK` macro = `!(DCR.LS) && TCR.LB`, so
  with `DCR=0x48` loopback never activates.**
- Default I/O base `0x300`; a probe path must be allowed for alternative
  bases later (`0x320/0x340/0x360`), but stage-1 utilities may hardcode
  `0x300`.
- Polling driver first; do not depend on IRQ until early stages succeed.
- Page select via `CR` bits 6..7. Useful explicit constants: `0x21` (page 0,
  stop, abort DMA), `0x22` (page 0, start), `0x61` (page 1, stop), `0x62`
  (page 1, start), `0xA1` (page 2, stop). Page 3 is not required for any
  current stage — RTL8019AS ID `Pp` is on **page 0** registers `0x0A` /
  `0x0B` (8019ID0 / 8019ID1 = `0x50` / `0x70`), confirmed against the
  Realtek datasheet and the MAME `dp8390.cpp` implementation.
- Remote DMA command bytes (low 6 bits of CR; OR with the page bits as
  needed): `0x0A` = remote read + STA, `0x12` = remote write + STA,
  `0x1A` = send packet + STA, `0x22` = abort/complete remote DMA + STA.
- RTL8019AS byte-mode packet RAM layout: `TPSR=0x40`, `PSTART=0x46`,
  `PSTOP=0x60`, `BNRY=0x46`, `CURR=0x47`, page size 256 bytes. The
  datasheet limits PSTOP to 0x60 when `DCR.WTS=0`; 0x80 is only valid in
  16-bit mode. PROM (MAC + signature)
  is read by remote DMA from `RSAR=0x0000` with `RBCR=32` and `CR=0x0A`.
- Reset is full NE2000-style, never a single write:
  ```
  tmp = IN  BASE+0x1F
  OUT BASE+0x1F, tmp
  delay 2 ms
  tmp = IN  BASE+0x1F
  wait ISR.RST == 1, timeout 100 ms
  OUT BASE+0x07, 0xFF      ; clear ISR
  ```
  Truncated reset is allowed only as a fallback and must emit
  `[W01] RESET.RST timeout, continuing soft init`.
- PROM signature is a NE2000-like sanity check, not a hard gate. `NICINFO`
  reads 32 bytes of PROM and prints `PROM[0E..0F]=...`,
  `PROM_LAYOUT=direct|doubled|unknown`, `MAC=...`. `RESULT FAIL` only when
  the 8019ID is not `Pp` AND a valid MAC cannot be extracted; mismatched
  `0x57 0x57` signature is a `WARN`, not a fatal error.
- Pad TX frames shorter than 60 bytes (without FCS) up to 60 bytes.
- ARP cache holds 1..4 entries. Eviction policy: update existing entry on
  hit; otherwise use the first free slot; otherwise replace the oldest
  entry. No timestamps required beyond an insertion order counter.
- All waits (reset, RDC, TX complete, RX, ARP, UDP reply, TCP retransmit)
  must have explicit timeouts and emit diagnostic output on expiry.

### ISA window discipline (mandatory)

On Sprinter the RTL8019AS is reached by memory-mapping the ISA card into
the `0xC000..0xFFFF` window (MMU page 3, port `0xE2`) via `ISA.ISA_OPEN`;
`ISA.ISA_CLOSE` restores the normal page-3 mapping. This window overlaps
the exact memory the Sprinter system/DSS uses — including where the ~50 Hz
system interrupt handler runs and where DSS keeps its state (env at
`0xE400`, etc.). The following rules are **non-negotiable**; they were
learned the hard way during real-hardware bring-up (violating them produced
`0xFF` reads on the remote-DMA data port, on-screen character corruption,
minute-long hangs that ignored Esc, and spontaneous power-off):

- **Interrupts MUST be disabled the whole time the ISA window is open.**
  Bracket every open/work/close as `DI` → `ISA_OPEN` → chip access →
  `ISA_CLOSE` → `EI`. If a system interrupt fires while the window is
  mapped, the ISR executes *over the ISA card* instead of system RAM and
  corrupts the chip state (stray writes can even hit the reset/data ports)
  and/or system memory. `ISA.ISA_OPEN` therefore does `DI` as its first
  act and `ISA.ISA_CLOSE` does `EI` as its last — do not defeat this.
- **Keep the open period as SHORT as possible.** Open the window only for
  the actual chip access (a register read/write, or one remote-DMA burst),
  then close it again. Holding it open across long stretches starves the
  system interrupt and destabilises the whole machine. In particular,
  perform delays/waits/poll-pacing with the window **CLOSED** (interrupts
  on) — e.g. `TICK_AND_CHECK_KEY` must `ISA_CLOSE` *before* its `DELAY`,
  then reopen only to touch the chip. Never `DELAY` with the window open.
- **NEVER call DSS or BIOS while the ISA window is open.** Any DSS/BIOS
  service (screen print/`PCHARS`, `ENVIRON`/`SETENV`, file I/O, `SCANKEY`,
  `APPINFO`, paged-memory/EMM calls, etc.) may remap MMU page 3, re-enable
  interrupts, and/or touch page-3 RAM — all of which trash the open ISA
  window and the chip data in it. Always `ISA_CLOSE` *before* the DSS/BIOS
  call and `ISA_OPEN` *after*.
- **Capture-then-print.** Read everything you need from the chip into plain
  Z80 RAM with the window open (IRQs off, no DSS calls in between), then
  `ISA_CLOSE` and only then format/print it. Do not interleave chip reads
  with DSS prints (the reg dumps in NICINFO/NICRAM/ping that print while the
  window is open are exactly this anti-pattern and read garbage on real HW).
- **Driver primitives may assume the caller already opened the window**
  (they run inside one DI/open/close bracket), but they must not call
  DSS/BIOS themselves and must not leave the window open longer than the
  single operation needs.

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
- `NICLB.EXE` confirms `PTX OK` plus the receive side appropriate to the
  target. The current MAME branch stores the internal-loopback frame in
  RX SRAM, so MAME must pass the header/payload comparison. A physical
  RTL8019AS does not store loopback packets in SRAM and does not set
  `ISR.PRX` (RTL8019AS datasheet section 6.6.2); on real hardware NICLB
  instead captures and reports the diagnostic FIFO plus ISR/RSR. External
  RX SRAM is then verified by `NICRX.EXE`.
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
