# NETCFG.EXE

Reads `NET.CFG` and publishes parsed values into DSS environment
variables, or displays them.  See `HOWTO.TXT` for the full list of
recognised `NET.CFG` keys and the resulting env vars.

## Usage

```
NETCFG          show current NET_* env values
NETCFG -i       init: load NET.CFG into NET_* env vars
NETCFG -c       check NET.CFG syntax (no env writes)
NETCFG -d       delete all NET_* env vars
NETCFG -w       interactive wizard: create/edit NET.CFG
NETCFG /?       help (-? -h also accepted)
```

## `-w`: interactive wizard

`NETCFG -w` walks through every key in order -- `RTL_RESET`, an optional
card probe, `RTL_HW`, `RTL_TYPE`, `RTL_MAC`, `IP` (or `DHCP`), and, only when `IP` is
not `DHCP`, `NETMASK`/`GATEWAY`/`DNS1`/`DNS2`, then `TZ` and `NTP` -- and
writes a fresh, canonical `NET.CFG`. Each prompt shows the current value
in brackets:

```
RTL_HW [1/#300]:
```

Above each prompt the wizard prints a short hint: what the key means,
an example value, and what leaving it empty does. The two that matter
most are spelled out in full -- `RTL_RESET` (what AUTO / SOFT / HARD do,
and that HARD freezes the computer on some NE2000 clones) and the probe
(safe with AUTO and SOFT; with HARD it warns first and defaults to No).
A hint is shown once per key; a rejected value repeats only the prompt.

A blinking `_` cursor sits at every prompt, including the probe
question, so a wizard waiting for input is never mistaken for a hung
one.

Press Enter to keep it, type a new value and press Enter to replace it,
type a lone `-` and press Enter to clear an optional field, Backspace to
correct a typo, or Esc at any point to abandon the wizard -- the existing
file (if any) is untouched until every field has validated and the whole
thing is written at once.

Esc means the same thing at every step, including the probe question.

If no `NET.CFG` exists yet, the wizard starts from the same defaults as
`config/NETSMPL.CFG` (`IP=DHCP`, `NTP=pool.ntp.org`, `TZ=+3`). If one
exists but cannot be read, `-w` refuses to touch it (exit 4) rather than
risk overwriting something the parser choked on for an unrelated reason.

Defaults shown in brackets are already canonical, so pressing Enter
through the whole wizard rewrites the file without changing its meaning.
`TZ` is the one key the loader hands over unparsed, so the wizard
validates it too: an existing `TZ=` line it cannot canonicalize (say
`TZ=+5:3`) is offered as an empty default rather than written back
unchanged, and an empty `TZ=` means UTC.

**The rewrite is canonical, not an edit in place.** Comments and any key
the wizard does not know about (`RTL_IRQ=`, for instance) are not
preserved -- every run produces the same ten `KEY=value` lines in the
same order. `RTL_RESET=AUTO` is written as an *empty* `RTL_RESET=` line
(the parser treats absent and empty the same way); typing `AUTO` at the
prompt is just the readable spelling of that.

**The probe step is optional** (`Probe for the card now [Y/n]?`). The
default is Yes, except when `RTL_RESET` is `HARD`: then the wizard warns
that a probe pulses the board reset port, which can hang some NE2000
clones, and the default becomes No (`[y/N]`). That is why `RTL_RESET` is
asked first. The probe reuses `NETCFG -i`'s own MAC-from-PROM path: the
`RTL_RESET` answer and the `RTL_HW` value already in `NET.CFG` (if any)
are published to the environment first, exactly as `-i` does, and a
missing or wrong `RTL_HW` falls back to the driver's auto-scan. A
successful probe shows the MAC it found, and the discovered slot/base
becomes the default of the `RTL_HW` prompt that follows -- `RTL_HW` is
asked once, after the probe; a failed probe leaves that default as it
was, to be typed by hand or left empty (auto-scan). Either way, the
auto-scan inside `INIT_BASE` publishes `NET_RTL_HW` to the *current*
session's environment as a side effect -- that is `INIT_BASE`'s normal
behavior, not something `-w` does deliberately, and it does not affect
what gets written to `NET.CFG`. **`-w` never publishes `NET_*`
variables from what it wrote** -- run `NETCFG -i` afterwards to apply
the new file.

`RTL_TYPE=NE1000` selects packet RAM at `2000h..3FFFh`; `NE2000` selects
`4000h..5FFFh`. An empty value is AUTO. AUTO probes both RAM windows and
publishes `NET_RTL_TYPE` only for an unambiguous result. A classic NE1000
does not carry the Realtek `Pp` ID, so its slot/base must be pinned with
`RTL_HW=S/#HHH`; the broad ISA scan intentionally accepts only the Realtek
ID to avoid mistaking a floating bus for a card.

## The MAC address

With no `RTL_MAC=` line in `NET.CFG`, `NETCFG -i` reads the address out of
the card's own PROM and publishes it as `NET_MAC`.  That probe needs to
find the card, so `-i` publishes `NET_RTL_HW` and `NET_RTL_RESET` to the
environment *before* touching the hardware -- the driver reads both while
locating the chip.

AUTO type detection still touches the card when `RTL_MAC` is supplied. The
override is preserved; the access is needed to determine and publish the
packet-RAM layout. Set an explicit `RTL_TYPE` as well when configuration
must be applied without touching hardware.

If the address cannot be obtained, `NETCFG -i` **fails**: without
`NET_MAC` nothing downstream can run, so leaving the environment in that
state and reporting success would only move the error somewhere less
informative.  The reason decides the exit code:

```
[E2] card not found; check RTL_HW in NET.CFG
[E3] card found but PROM read failed
[E4] no MAC in card PROM; add RTL_MAC= to NET.CFG
```

The remaining variables are still published, so a plain `NETCFG`
afterwards shows how far the configuration got.  The fix is either to
make the card reachable (check `RTL_HW`) or to state the address by hand
with `RTL_MAC=`.

`-i` also settles how the card may be reset.  With no `RTL_RESET=` line
the driver reads the chip ID and pulses the board reset port at
`BASE+0x1F` only for a genuine Realtek; a clone gets the soft path and

```
[W03] non-Realtek clone: board reset port skipped
```

`NETCFG -i` then publishes `NET_RTL_RESET=SOFT` so later utilities and
`UNETRTL.DLL` inherit the answer instead of re-probing.  After a Realtek
the variable is deliberately left unset, so replacing the card with a
clone cannot carry a stale `HARD` over into a machine freeze.

The status is returned through `DSS_EXIT`, so a batch flow that can test
it should stop before `IFUP`.  Note that every `.BAT` shipped with this
kit and with the sibling Wi-Fi kit is a flat command sequence -- whether
the DSS batch interpreter supports `IF ERRORLEVEL` / `GOTO` has not been
verified here.

`NETCFG.EXE` is the only utility in the kit that opens `NET.CFG`.
All other utilities read from environment variables only. The file is
resolved beside the running `NETCFG.EXE` through DSS `APPINFO`, not
relative to the caller's current directory. `-i` and `-c` print
`[C0] CFG=<resolved path>` before opening it.

## Exit codes

| Code | Meaning                                           |
|------|---------------------------------------------------|
| 0    | OK                                                |
| 1    | Usage                                             |
| 2    | Card not found (`-i`, no MAC obtainable)          |
| 3    | Card found but its PROM could not be read (`-i`)  |
| 4    | Config error: bad/missing NET.CFG, or no MAC in PROM; or (`-w`) an existing NET.CFG could not be read |
| 5    | (`-w`) could not write NET.CFG                    |
| 7    | (`-w`) cancelled by the user (Esc)                |
