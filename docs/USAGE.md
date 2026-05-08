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
| `ARP.TXT`     | Single ARP probe                                     |
| `PING.TXT`    | ICMP echo                                            |
| `UDPTEST.TXT` | UDP echo smoke test                                  |
| `NSLOOKUP.TXT`| DNS A-record lookup                                  |
| `NTP.TXT`     | NTPv3 client; sets the DSS clock                     |
| `WGET.TXT`    | HTTP download with redirect following                |
| `FTP.TXT`     | FTP download + directory listing                     |
| `TFTP.TXT`    | TFTP download with RFC 2348 blksize                  |
| `ISAPROBE.TXT`| ISA bus diagnostic when NICINFO can't find the card  |

The `NIC*` utilities (`NICINFO`, `NICRAM`, `NICLB`, `NICTX`,
`NICRX`) are stage diagnostics for the driver itself; their use
is described in `sprinter_rtl8019_soft.md` in the source tree, not
shipped on the floppy.

For driver-level details, NIC register descriptions, and MAME
network setup see `sprinter_rtl8019_soft.md` and
`docs/MAME_NETWORK.md` in the source tree.
