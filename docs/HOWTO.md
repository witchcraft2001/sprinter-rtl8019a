# Sprinter RTL8019AS Network Kit -- HOWTO

Conventions, configuration, exit codes and batch examples shared
across every utility in the kit.  Per-utility command details
live in the matching `<NAME>.TXT` document.

For driver-level details, NIC register descriptions, MAME network
setup, and stage-by-stage internals see `sprinter_rtl8019_soft.md`
and `docs/MAME_NETWORK.md` in the source tree.


## Command-line flags

All utilities follow a DOS / Windows convention:

- Flags are single ASCII characters with either prefix: `-x` and
  `/x` are equivalent.  Letter case is not significant.
- A flag that takes a value reads the *next* token: `-n 5`, not
  `-n5` or `-n=5`.
- Long flags (`--xxx`) are NOT supported.
- Help is requested with `/?`, `-?`, or `-h` (any of these).


## Exit codes

Every utility writes one of these values to `ERRORLEVEL` on exit
(register `B` at `DSS_EXIT`).  Batch scripts can branch on them:

| Code | Meaning                                                       |
|------|---------------------------------------------------------------|
| 0    | OK                                                            |
| 1    | Usage error (unknown / missing / malformed argument)          |
| 2    | RTL8019AS not detected at the configured I/O base             |
| 3    | Network error (ARP / ICMP / UDP / TCP timeout, no route, etc.)|
| 4    | Configuration error (`NET.CFG` missing, or `NET_*` env var    |
|      | not set -- run `NETCFG -i` first)                             |
| 5    | File create / write / close failure (download utilities)      |

Each utility prints `RESULT OK` (`B=0`) or `RESULT FAIL` (`B != 0`)
as its last line, so visual inspection in MAME and machine-readable
batch checks agree.


## Cancelling a wait

Utilities that wait for the network respond to **Esc** and
**Ctrl+C** while polling for replies.  A cancelled run prints
`Aborted by user (Esc/Ctrl+C).` and returns `B=3`.


## Hostnames vs IPv4 literals

Utilities that take a destination (`PING`, `UDPTEST`, `TFTP`,
`NTP`, `WGET`, `FTP`) accept either a dotted-decimal IPv4 address
or a DNS hostname.  When a hostname is supplied, the utility issues
a DNS A-record query to `NET_DNS1` before the actual operation.
If `NET_DNS1` is unset, the utility prints a configuration error
-- pass an IPv4 literal or run `NETCFG -i` / `IFUP` first.

For *off-subnet* destinations (anything outside `NET_IP &
NET_MASK`) the utility ARPs `NET_GW` instead of the target itself;
without a valid `NET_GW` the operation fails with
`[E] off-subnet but NET_GW unset`.

`NSLOOKUP` is a separate utility for explicit DNS testing; the
inline resolver in the other utilities uses the same library.


## Output paths (`-o`)

Utilities that download (`WGET`, `FTP`, `TFTP`) accept an output
filename that may include a directory part:

| Form                           | Effect                          |
|--------------------------------|---------------------------------|
| `file.zip`                     | save in current working dir     |
| `test\file.zip`                | save into existing `test\` dir  |
| `\file.zip`                    | save in volume root             |
| `C:\foo\bar\file.zip`          | absolute path, drive included   |

The kit splits the path at the last `/` or `\` (both accepted),
CHDIRs into the directory for the duration of the file create,
then restores the previous working directory before returning.
A non-existent directory prints `[E] directory not found: <dir>`
and the utility exits with `B=1`; the kit does NOT auto-create
intermediate directories.


## Configuration

The kit relies on DSS environment variables populated by
`NETCFG -i` from `NET.CFG`:

| Variable        | Source / role                                    |
|-----------------|--------------------------------------------------|
| `NET_IP_SRC`    | `STATIC` or `DHCP` (selects how IFUP runs)       |
| `NET_IP`        | Local IPv4 (set by `NETCFG -i` for STATIC,       |
|                 | by `IFUP` for DHCP)                              |
| `NET_MASK`      | Subnet mask                                      |
| `NET_GW`        | Default gateway                                  |
| `NET_MAC`       | Local MAC (always populated by `NETCFG -i`)      |
| `NET_DNS1/2`    | DNS servers                                      |
| `NET_NTP`       | Default NTP server                               |
| `NET_TZ`        | Timezone offset (signed integer hours)           |
| `NET_RTL_HW`    | ISA slot + I/O base for the chip, `S/#HHH` form  |
|                 | (e.g. `1/#300`); set by `NETCFG -i` from         |
|                 | `RTL_HW=` or by the auto-scan in `INIT_BASE`     |
|                 | when net.cfg doesn't pin it down                 |
| `NET_DHCP_SRV`  | DHCP server that issued the lease (DHCP only)    |
| `NET_LEASE_SEC` | Remaining lease seconds (DHCP only)              |

Bring-up sequence (typical `AUTOEXEC.BAT`):

```text
NETCFG -i
IF ERRORLEVEL 4 GOTO NOCFG
IFUP
IF ERRORLEVEL 3 GOTO NOLINK
```

Without `NETCFG -i` the network utilities exit `B=4` with a
diagnostic.  IFUP picks STATIC vs DHCP from `NET_IP_SRC`.

`NET.CFG` keys recognised by the parser:

```text
IP=192.168.7.5            IPv4 literal -> static config
IP=DHCP                   request a DHCP lease from IFUP
NETMASK=255.255.255.0     ignored when IP=DHCP
GATEWAY=192.168.7.1       ignored when IP=DHCP
RTL_MAC=02:80:19:11:22:33 optional MAC override (empty -> use PROM)
RTL_HW=1/#300             ISA slot + I/O base ("S/HHH"); accept
                          optional "#" or "0x" prefix on HHH;
                          omit to auto-scan
DNS1=1.1.1.1              ignored when IP=DHCP
DNS2=8.8.8.8              ignored when IP=DHCP
NTP=pool.ntp.org          for NTP.EXE
TZ=+3                     signed integer hours
```

Lines starting with `#` are comments; unknown keys are ignored.

`NETCFG -i` sets `NET_IP_SRC` to `STATIC` or `DHCP` based on the
`IP=` line.  In DHCP mode it deletes any stale `NET_IP / NET_MASK
/ NET_GW / NET_DNS1 / NET_DNS2` so a previous lease does not
linger; `IFUP` then populates them from the DHCP reply.

`NETCFG.EXE` is the only utility in the kit that opens `NET.CFG`.
All other utilities read from environment variables only.


## Batch examples

A typical `AUTOEXEC.BAT` fragment to bring the network up:

```text
NETCFG -i
IF ERRORLEVEL 4 GOTO NOCFG
IFUP
IF ERRORLEVEL 3 GOTO NOLINK
PING -n 1 192.168.7.1
IF ERRORLEVEL 3 GOTO NOLINK
ECHO Network up.
GOTO END
:NOCFG
ECHO NET.CFG missing or invalid; copy NETSMPL.CFG to NET.CFG.
GOTO END
:NOLINK
ECHO Gateway unreachable.
:END
```

Polling a service before continuing:

```text
:WAIT
PING -n 1 192.168.7.1
IF ERRORLEVEL 3 GOTO WAIT
ECHO Gateway is up.
```

Conditional download:

```text
TFTP 192.168.7.1 GET BOOT.BIN
IF ERRORLEVEL 1 ECHO Download failed
```

HTTP fetch with overwrite + status-aware exit:

```text
WGET http://192.168.7.1/BOOT.BIN -y
IF ERRORLEVEL 3 ECHO HTTP error -- check the [E] line above
IF ERRORLEVEL 1 GOTO HFAIL
ECHO Download OK.
GOTO :EOF
:HFAIL
ECHO Download failed.
```

Listing a remote FTP directory before pulling a specific file:

```text
FTP server.lan -l -u alice -p secret
FTP server.lan target.zip -u alice -p secret -y
```


## Versioning

Per-utility version is printed in the banner.  Current versions
in this release:

| Utility   | Banner     |
|-----------|------------|
| ARP       | v0.2       |
| FTP       | v0.3       |
| IFUP      | v0.2       |
| ISAPROBE  | v0.1       |
| NETCFG    | v0.1       |
| NICINFO   | v0.1       |
| NICLB     | v0.1       |
| NICRAM    | v0.1       |
| NICRX     | v0.1       |
| NICTX     | v0.1       |
| NSLOOKUP  | v0.1       |
| NTP       | v0.3       |
| PING      | v0.2       |
| TFTP      | v0.5       |
| UDPTEST   | v0.2       |
| WGET      | v0.2.1     |

Major behavioural changes bump the second digit; the first digit
moves to `v1.0` after a real-hardware bring-up pass on the
physical RTL8019AS card.
