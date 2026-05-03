# Sprinter RTL8019AS Network Kit

Network stack and minimal utility set for Sprinter DSS targeting the ISA-8
Ethernet card based on Realtek RTL8019AS / DP8390. Also a development kit
for reusing the driver and stack in other Sprinter DSS programs.

The full staged development plan, register map and acceptance criteria
live in `sprinter_rtl8019_soft.md` (project specification). Repository
guidelines and conventions are in `AGENTS.md` / `CLAUDE.md`. Developer
notes for MAME network setup are in `docs/MAME_NETWORK.md`.

## Status

Bootstrap. Stage 0 (`HELLO.EXE`) only.

## Installing on Sprinter DSS

The `distr/sprinter-rtl8019a.zip` archive and the FAT12 floppy image both
ship 8.3 names so they can be unpacked / copied directly onto the target
FAT16 hard disk. After unpacking, configure networking by renaming the
sample config:

```
REN NETSMPL.CFG NET.CFG
```

Then edit `NET.CFG` for your local network (`RTL_IOBASE`, `IP`, `NETMASK`,
`GATEWAY`, ...).

## Build

Requires `sjasmplus` in `PATH`. `make package` additionally needs `zip`;
`make image` additionally needs `mtools` (`mformat`, `mcopy`).

```
make build      # assemble src/apps/*.asm into build/*.EXE
make package    # produce distr/sprinter-rtl8019a.zip
make image      # produce distr/sprinter-rtl8019a.img (FAT12 floppy)
make clean      # remove build/ and the two distr artifacts
```

Direct sjasmplus invocation for a single source:

```
sjasmplus -I src/include -I src/lib --raw=build/HELLO.EXE src/apps/hello.asm
```

## Running in MAME

```
/Users/dmitry/dev/zx/sprinter/mame/mame sprinter -isa1 rtl8019as
```

For network stages (4+) see `docs/MAME_NETWORK.md`.

## Layout

```
src/include/      shared includes (DSS, Sprinter, RTL8019AS constants, macros)
src/lib/          reusable driver and stack modules (planned)
src/apps/         utility entry points
config/           NET.CFG.sample
docs/             user docs (shipped) and developer docs (not shipped)
examples/         DSS batch files and host-side helpers
tools/            build / package / image scripts and dev helpers
build/            generated EXE outputs (ignored)
distr/            generated zip and floppy image (ignored)
```
