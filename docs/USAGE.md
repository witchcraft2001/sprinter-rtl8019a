# Sprinter RTL8019AS Network Kit -- Index

This is the entry point for the user-facing documentation shipped
in the kit.  Common conventions, configuration, exit codes, and
batch examples live in `HOWTO.TXT`; each utility has its own
short reference page.

Read these in order on a fresh setup:

1. `HOWTO.TXT` -- conventions, env vars, exit codes, batch idioms.
2. `NETCFG.TXT` -- `NETCFG -i` to seed env from `NET.CFG`.
3. `IFUP.TXT`   -- bring the link up (static or DHCP).
4. `PING.TXT`   -- verify reachability.

Then use whichever utility you need.  All `<NAME>.TXT` files use
the same layout: usage syntax, options, examples, exit codes.

| File          | Utility / topic                                      |
|---------------|------------------------------------------------------|
| `HOWTO.TXT`   | Common conventions and configuration (start here)    |
| `NETCFG.TXT`  | NET.CFG / env-var management                         |
| `IFUP.TXT`    | Static or DHCP interface bring-up                    |
| `PING.TXT`    | ICMP echo                                             |
| `NSLOOKUP.TXT`| DNS A-record lookup                                  |
| `NTP.TXT`     | NTPv3 client; sets the DSS clock                     |
| `WGET.TXT`    | HTTP download with redirect following                |
| `FTP.TXT`     | FTP download + directory listing                     |
| `TELNET.TXT`  | ANSI/VT100 Telnet client with Zmodem/Ymodem          |
| `TFTP.TXT`    | TFTP download with RFC 2348 blksize                  |
| `ISAPROBE.TXT`| ISA bus troubleshooting and raw window inspection    |
| `NICEEP.TXT`  | Read-only dump of a jumperless card's 93C46 EEPROM   |
| `NICREG.TXT`  | Register read-stability test for a marginal ISA bus  |
| `UNETRTL.TXT` | UNET DLL: TCP/UDP/DNS/ping, two channels, developer API |

`UNETRTL.DLL` is for developers: it exposes the kit's network stack
to your own DSS programs through the same numbered API the Sprinter
Wi-Fi kit implements, so one binary can drive either card.  The
ready-built DLL is also committed at the repository root and ships in
the archive and floppy image.

`NICINFO.EXE` prints the detected RTL8019AS identity, MAC address, packet
RAM layout, and register snapshot. If the card is not detected normally,
use `ISAPROBE.EXE` with the procedures in `ISAPROBE.TXT`.

For a classic NE1000, set `RTL_HW=S/#HHH` and either leave `RTL_TYPE=` empty
for the RAM probe or set `RTL_TYPE=NE1000`.  `NETCFG -i` publishes the
canonical `NET_RTL_TYPE`; malformed values stop utilities with exit code 4.
NE1000 uses packet RAM pages `20h..3Fh`; NE2000/RTL8019 uses `40h..5Fh`.

For driver-level details, NIC register descriptions, and MAME
network setup see `sprinter_rtl8019_soft.md` and
`docs/MAME_NETWORK.md` in the source tree.

Developer floppy diagnostic: `UNETTEST -r SLICE HOST PORT` verifies a full
8192-byte HTTP body against the supplied host response server. `SLICE=0`
is blocking, `25` uses SENDSLICE. Exit 0 requires exact content, CRC32 and
EOF without LOST; exit 3 reports transport/content failure, 1 usage,
2 DLL/load/hardware failure, 4 missing network configuration.
See UNETRTL.TXT for the response format and host helper.

Developer floppy diagnostic: `DLWIN3 URL` is an experimental DLDIRECT with
a 4380-byte TCP receive window (ordinary DLDIRECT keeps 2920). It discards
the body without disk writes. See DLSPEED.TXT for A/B capture instructions.
Exit codes: 0 success, 1 usage, 2 missing NIC, 3 network/HTTP/RTC/cancel
error, 4 missing network environment. Not a production FTP/WGET change.

Developer floppy diagnostic: `DLOOO3 URL` is the DLWIN3 experiment with a
two-segment out-of-order TCP receive queue. It keeps MSS 1460 and the
4380-byte receive window; its post-transfer `OOO saved/delivered/nospace/max`
counters show whether the queue was used. It is excluded from the release
ZIP. The same exit codes as DLWIN3 apply. Russian note: очередь сохраняет
только два сегмента впереди ожидаемого; ACK не продвигается через пропуск.

Developer floppy diagnostic: `DLTUNE [-w 3|6|9] [-a 1|2] URL` measures the
direct one-session TCP experiment with two OOO slots. `-w` selects a maximum
receive window of 3, 6, or 9 MSS; the SYN always announces 4380 bytes. `-a`
selects ACK every one or two segments. Options may appear before or after the
URL; unknown, repeated, or invalid values are usage errors. The decimal
report includes OOO saved/delivered/nospace/max, duplicate/overlap/invalid
frame counters, and the existing NIC error counters. DLTUNE is developer-
image-only and excluded from the release ZIP.

## Author

Sprinter RTL8019AS Network Kit -- Dmitry Mikhalchenkov,
FidoNet: 2:5030/1997.10
