# Sprinter RTL8019AS Network Kit -- Usage

This document describes the user-facing utilities shipped in the
Sprinter RTL8019AS network kit: command syntax, output, exit codes,
and typical batch examples.  It is intended to be read on the
Sprinter (the build pipeline copies it to `USAGE.TXT` on the floppy
image and inside the zip distribution).

For driver-level details, NIC register descriptions, MAME network
setup, and stage-by-stage internals see `sprinter_rtl8019_soft.md`
and `docs/MAME_NETWORK.md` in the source tree.


## Conventions

### Command-line flags

All utilities follow a DOS / Windows convention:

- Flags are single ASCII characters with either prefix: `-x` and
  `/x` are equivalent.  Letter case is not significant.
- A flag that takes a value reads the *next* token: `-n 5`, not
  `-n5` or `-n=5`.
- Long flags (`--xxx`) are NOT supported.
- Help is requested with `/?`, `-?`, or `-h` (any of these).

### Exit codes

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

Each utility prints `RESULT OK` (`B=0`) or `RESULT FAIL` (`B != 0`)
as its last line, so visual inspection in MAME and machine-readable
batch checks agree.

### Cancelling a wait

Utilities that wait for the network (PING, ARP, UDPTEST, TFTP)
respond to **Esc** and **Ctrl+C** while polling for replies.  A
cancelled run prints `Aborted by user (Esc/Ctrl+C).` and returns
`B=3`.

### Configuration

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


## NETCFG.EXE

`NETCFG` reads `NET.CFG` and publishes parsed values into DSS
environment variables, or displays them.

```
NETCFG          show current NET_* env values
NETCFG -i       init: load NET.CFG into NET_* env vars
NETCFG -c       check NET.CFG syntax (no env writes)
NETCFG -d       delete all NET_* env vars
NETCFG /?       help (-? -h also accepted)
```

Exit codes: 0 ok, 1 usage, 4 config (with `-i` / `-c` only).

`NET.CFG` keys recognised by the parser:

```text
IP=192.168.7.5            IPv4 literal -> static config
IP=DHCP                   request a DHCP lease from IFUP
NETMASK=255.255.255.0     ignored when IP=DHCP
GATEWAY=192.168.7.1       ignored when IP=DHCP
RTL_MAC=02:80:19:11:22:33 optional MAC override
DNS1=1.1.1.1              ignored when IP=DHCP
DNS2=8.8.8.8              ignored when IP=DHCP
NTP=pool.ntp.org          for NTP.EXE (future)
TZ=+3                     signed integer hours
```

Lines starting with `#` are comments; unknown keys are ignored.

`NETCFG -i` sets `NET_IP_SRC` to `STATIC` or `DHCP` based on the
`IP=` line.  In DHCP mode it deletes any stale `NET_IP / NET_MASK /
NET_GW / NET_DNS1 / NET_DNS2` so a previous lease does not linger;
`IFUP` then populates them from the DHCP reply.

`NETCFG.EXE` is the only utility in the kit that opens `NET.CFG`.
All other utilities read from environment variables only.


## IFUP.EXE

Brings the network interface up.  Behaviour depends on
`NET_IP_SRC`:

- **STATIC**: just verifies that `NET_IP` and `NET_MAC` are set
  and prints the assigned address.
- **DHCP**: runs the full DHCP cycle (DISCOVER -> OFFER -> REQUEST
  -> ACK), then `SETENV`s `NET_IP`, `NET_MASK`, `NET_GW`,
  `NET_DNS1`, `NET_DNS2`, `NET_DHCP_SRV`, `NET_LEASE_SEC`.

```
IFUP            bring interface up per NET_IP_SRC
IFUP /?         help
```

Example (DHCP):

```
RTL8019AS IFUP v0.2

DHCP: sending DISCOVER...
DHCP: got OFFER 192.168.7.100 (server 192.168.7.1)
DHCP: lease IP=192.168.7.100 (server 192.168.7.1, lease 3600 s)
RESULT OK
```

Exit codes: 0 ok, 1 usage, 2 no NIC, 3 DHCP timeout / cancel,
4 config (NET_MAC missing, or NET_IP missing in static mode).

Esc and Ctrl+C abort the DHCP wait.

`IFUP -r` (renew) and `IFUP -d` (release) are planned for a later
iteration.


## ARP.EXE

Single ARP probe.  Resolves an IPv4 to a MAC and prints it.

```
ARP target
ARP /?
```

`target` is the destination IPv4 (e.g. `192.168.7.1`).

Example output:

```
RTL8019AS ARP v0.2

ARPING 192.168.7.1 from 192.168.7.5 (02:80:19:11:22:33)
Reply from 192.168.7.1: 66:65:74:68:00:01
RESULT OK
```

Exit codes: 0 ok, 1 usage, 2 no NIC, 3 ARP timeout / cancel,
4 config.

The current ARP cache is 1..4 entries inside the running utility
and is not persisted; an "arp -a" listing is not available in v0.2.


## PING.EXE

Sends ICMP echo requests, prints replies and per-run statistics.

```
PING [-t] [-n count] [-l size] [-i TTL] [-w ms] target
PING /?
```

| Option   | Meaning                                                |
|----------|--------------------------------------------------------|
| `-t`     | Ping until interrupted (Esc / Ctrl+C).                 |
| `-n N`   | Number of echo requests (default 4, max 255).          |
| `-l N`   | Payload size in bytes (default 32, max 255).           |
| `-i TTL` | IP TTL on outgoing requests (default 64).              |
| `-w MS`  | Per-reply wait timeout in milliseconds (default 1000). |
| `target` | Destination IPv4.                                      |

`-t` and `-n` are mutually compatible: when `-t` is supplied, the
count from `-n` is ignored and the loop continues until the user
cancels.

Example output:

```
RTL8019AS PING v0.2

Pinging 192.168.7.1 with 32 bytes of data:
Reply from 192.168.7.1: bytes=32 time<1ms TTL=64
Reply from 192.168.7.1: bytes=32 time<1ms TTL=64
Reply from 192.168.7.1: bytes=32 time<1ms TTL=64
Reply from 192.168.7.1: bytes=32 time<1ms TTL=64

Ping statistics for 192.168.7.1:
    Packets: Sent = 4, Received = 4, Lost = 0.
RESULT OK
```

Exit codes: 0 if at least one reply was received, 3 if all timed
out, 1 usage, 2 no NIC, 4 config.

Timing resolution on the Sprinter Z80 is below 1 ms for LAN
exchanges, so all replies show `time<1ms`.  A finer resolution
is planned alongside a per-reply RTT measurement upgrade.


## UDPTEST.EXE

Sends a fixed 16-byte payload (`SPRINTER UDPTEST`) to the given
host:port and waits for an echo reply.  Useful for smoke-testing
UDP through a host-side `udp_echo.py` (see `tools/dev/`).

```
UDPTEST host port
UDPTEST /?
```

| Option | Meaning                            |
|--------|------------------------------------|
| `host` | Destination IPv4                   |
| `port` | Destination UDP port (1..65535)    |

Example output:

```
RTL8019AS UDPTEST v0.2

Sending UDP to 192.168.7.1:7777 from 192.168.7.5
Reply: len=16 data=SPRINTER UDPTEST
RESULT OK
```

Exit codes: 0 ok, 1 usage, 2 no NIC, 3 ARP/UDP timeout, 4 config.

Custom payload and a `-l` size flag are planned for a later
iteration.


## TFTP.EXE

Minimal TFTP client (RFC 1350, octet mode, 512-byte blocks).
Only `GET` is implemented in v0.2.

```
TFTP host GET filename
TFTP /?
```

| Option     | Meaning                                              |
|------------|------------------------------------------------------|
| `host`     | TFTP server IPv4                                     |
| `GET`      | Fetch operation (only mode supported in v0.2)        |
| `filename` | Remote file; saved locally under the same name       |

Example:

```
RTL8019AS TFTP v0.2

GET TEST.TXT from 192.168.7.1
Done. 25 bytes received.
RESULT OK
```

The local filename is identical to the remote filename; renaming
and `PUT` arrive in a later iteration.

Exit codes: 0 ok, 1 usage (including `PUT`), 2 no NIC,
3 ARP/TFTP timeout / server error, 4 config.

Cancelling with Esc/Ctrl+C closes the partial output file.


## NSLOOKUP.EXE

Single-shot DNS resolver.  Sends one A-record query over
UDP/53 and prints the first address from the answer.

```
NSLOOKUP host [server-ip]
NSLOOKUP /?
```

| Option       | Meaning                                                |
|--------------|--------------------------------------------------------|
| `host`       | Hostname to resolve (e.g. `pool.ntp.org`).             |
| `server-ip`  | Optional DNS server IPv4.  Defaults to `NET_DNS1`.     |

Next-hop selection: if the DNS server is on the same
subnet as `NET_IP` (using `NET_MASK`), NSLOOKUP ARPs the
server directly.  Otherwise it ARPs `NET_GW` -- so an
upstream resolver like `8.8.8.8` requires a working
gateway plus host-side NAT or routing.  Without
`NET_MASK` the server is assumed reachable directly.

Example:

```
RTL8019AS NSLOOKUP v0.1

Querying google.com at 192.168.7.1 from 192.168.7.101
Name:    google.com
Address: 74.125.205.113
RESULT OK
```

Exit codes: 0 ok, 1 usage / invalid hostname,
2 no NIC, 3 ARP/DNS timeout / server returned NXDOMAIN
or no A record, 4 config (`NET_DNS1` missing without
`server-ip` arg, or off-subnet server with no `NET_GW`).

Only A records and a single-question query are handled
in v0.1; AAAA, CNAME chasing, MX, and multi-question are
not supported.  Recursion is delegated to the server
(RD=1 in the query).


## NTP.EXE

Minimal NTPv3 client.  Sends a 48-byte client query to UDP
port 123, receives the server's reply, and prints the time
in UTC and local timezone.

```
NTP server-ipv4
NTP /?
```

| Option         | Meaning                                          |
|----------------|--------------------------------------------------|
| `server-ipv4`  | Numeric IPv4 of the NTP server.  No DNS yet, so |
|                | provide a literal address.                       |

Example:

```
RTL8019AS NTP v0.1

Querying NTP at 192.168.7.1 from 192.168.7.119
Reply: stratum=2
NTP transmit timestamp: 0xEDA5F312 (seconds since 1900-01-01)
UTC time:   2026-05-06 17:04:18
Local time: 2026-05-06 22:04:18 (TZ +5)
RESULT OK
```

The local-time line is computed by adding `NET_TZ` (signed
integer hours, e.g. `+3`, `-5`, `0`) to the UTC seconds.
Missing or unparseable `NET_TZ` is treated as UTC+0.

Exit codes: 0 ok, 1 usage, 2 no NIC, 3 ARP/NTP timeout,
4 config.

NTP currently does NOT write the parsed time back into the
DSS system clock (`DSS_SETTIME`).  This is a planned v0.2
addition.  For now the utility is read-only.


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


## Versioning

Per-utility version is printed in the banner (`v0.2` as of this
release).  Major behavioural changes will bump the second digit;
the first digit moves to `v1.0` once DHCP, NTP, WGET and FTP land.
