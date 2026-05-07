# Sprinter RTL8019AS Network Kit

Network stack and minimal utility set for Sprinter DSS targeting the ISA-8
Ethernet card based on Realtek RTL8019AS / DP8390. Also a development kit
for reusing the driver and stack in other Sprinter DSS programs.

The full staged development plan, register map and acceptance criteria
live in `sprinter_rtl8019_soft.md` (project specification). Repository
guidelines and conventions are in `AGENTS.md` / `CLAUDE.md`. Developer
notes for MAME network setup are in `docs/MAME_NETWORK.md`.

## Status

Stages 0..10 implemented and tested in MAME with a pcap
backend on macOS:

- `HELLO`, `NICINFO`, `NICRAM`, `NICLB`, `NICTX`, `NICRX`
  -- driver bring-up.
- `ARP`, `PING` (with `-t/-n/-l/-i/-w` Windows-style
  flags), `UDPTEST`, `TFTP`, `NTP`, `NSLOOKUP` -- IPv4
  + UDP utilities.
- `NETCFG`, `IFUP` (static + DHCP), `WGET` (HTTP/1.0),
  `FTP` (passive mode, work in progress).

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

For low-level driver / network-provider details (PROM layout,
reset sequence, RX ring header, pcap vs slirp on macOS) see
`docs/MAME_NETWORK.md`.  The section below covers the
**operational** test stand -- which host services to start
before each utility, and how to optionally share real
internet access into the emulator.

## Test stand setup

The kit's network utilities are tested against host-side
helpers that live next to MAME:

| Sprinter utility       | Host service / role                               |
|------------------------|---------------------------------------------------|
| `PING`, `ARP`          | none (kernel of the host replies natively)        |
| `IFUP` (DHCP mode)     | `dnsmasq` -- DHCP server                          |
| `NSLOOKUP`             | `dnsmasq` -- DNS forwarder (or local A records)   |
| `UDPTEST`              | `tools/dev/udp_echo.py` -- UDP echo (port 7777)   |
| `TFTP`                 | any TFTP server (`tftpd-hpa`, `dnsmasq --enable-tftp`) |
| `NTP`                  | `tools/dev/ntp_serve.py` -- minimal NTP responder |
| `WGET`                 | `python3 -m http.server` -- static HTTP/1.0       |
| `FTP`                  | `pyftpdlib` -- minimal FTP server (anonymous)     |

The same virtual interface (a host-only NIC at
`192.168.7.1/24`) carries every test.  Sprinter sees this
interface on the wire and either gets its IP via DHCP
(`IP=DHCP` in `NET.CFG`) or uses a static address
(typically `192.168.7.5`).  All host-side services bind to
`192.168.7.1` so the Sprinter side reaches them at that
address.

### macOS

macOS ships a BSD-style "fake Ethernet pair" (`feth0`,
`feth1`).  One end is plugged into MAME (`pcap`
backend), the other gets the host IP.  Setup once per boot:

```sh
sudo ifconfig feth0 create
sudo ifconfig feth1 create
sudo ifconfig feth0 peer feth1
sudo ifconfig feth0 up
sudo ifconfig feth1 inet 192.168.7.1/24 up
```

Verify:

```sh
ifconfig feth0
ifconfig feth1
```

Launch MAME pointing at `feth0` (the wire-side end).  The
launcher script
`/Users/dmitry/dev/zx/sprinter/mame/run_sprinter_rtl8019as.sh`
reads `MAME_RTL_NIC` from the environment (default `feth0`).

`/dev/bpf*` permissions are required for `pcap` to work.
First run typically needs:

```sh
sudo chmod o+r /dev/bpf*
```

(Resets after reboot; consider `chmod-bpf` from Wireshark
or a launchd plist for permanent access.)

Host services on macOS:

```sh
# DHCP + DNS forwarder (anonymous A records work too)
sudo dnsmasq -k --listen-address=192.168.7.1 --bind-interfaces \
  --dhcp-range=192.168.7.100,192.168.7.150,12h \
  --dhcp-option=3,192.168.7.1 --dhcp-option=6,192.168.7.1 \
  --server=1.1.1.1 --server=8.8.8.8 --no-resolv \
  --address=/sprinter.local/192.168.7.1

# HTTP for WGET (run from the directory you want to serve)
cd /tmp/web-test && sudo python3 -m http.server 80 --bind 192.168.7.1

# UDP echo for UDPTEST
python3 tools/dev/udp_echo.py

# NTP responder
sudo python3 tools/dev/ntp_serve.py --bind 192.168.7.1

# FTP (pyftpdlib) -- install once via venv:
python3 -m venv ~/ftpd-venv
~/ftpd-venv/bin/pip install pyftpdlib
sudo ~/ftpd-venv/bin/python -m pyftpdlib -p 21 -i 192.168.7.1 \
  -d /tmp/web-test -w
```

### Linux

Linux uses `veth` for a host-only pair.  One end stays in
the host namespace (it's the "host side"), the other is
left up but unconfigured -- MAME's `pcap` backend grabs
frames there.

```sh
sudo ip link add veth0 type veth peer name veth1
sudo ip addr add 192.168.7.1/24 dev veth1
sudo ip link set veth0 up
sudo ip link set veth1 up
```

Launch MAME with `-netdev pcap,name=veth0`.  Same `pcap`
permissions caveat -- on Linux you may need to grant
`CAP_NET_RAW` to the MAME binary or run as root once.

Host services are exactly the same as macOS.  `dnsmasq`,
`python3 -m http.server`, `pyftpdlib` etc. are all stock
packages (`apt install dnsmasq python3-pip` etc.).

### Windows

On Windows the simplest stack is **WSL2** running a Linux
distribution: keep MAME on the Windows side, run all host
services inside WSL2 using the Linux instructions above.
WSL2 brings its own virtual switch, so a `veth` pair plus
the standard services work as on bare Linux.

Native Windows-only setup is also possible but heavier:

- Install **Npcap** (libpcap port) so MAME's `pcap`
  backend can attach to a Windows interface.  Choose
  "Install Npcap in WinPcap API-compatible Mode" on the
  installer.
- Create a virtual NIC.  Easiest is the **Microsoft Loopback
  Adapter** (`hdwwiz.exe` -> "Add legacy hardware" ->
  "Network adapters" -> "Microsoft" -> "Microsoft KM-TEST
  Loopback Adapter").  Give it `192.168.7.1/24` in
  `Control Panel -> Network Connections -> properties`.
- Launch MAME with `-netdev pcap,name="Microsoft KM-TEST..."`.
- Install host services natively or via WSL2.  `dnsmasq` is
  not packaged for Windows; use a small Python equivalent
  or skip DHCP and configure `NET.CFG` statically.

For most testing WSL2 + Linux instructions are recommended.

### Internet access for the virtual interface

By default the host-only pair (`feth0/feth1`, `veth0/veth1`)
is **isolated** -- the Sprinter can talk to the host but
not to the public internet.  That's fine for `PING`, local
TFTP / FTP, dnsmasq-cached DNS, and anything served from
the host directly.  To reach the real internet (e.g. for
WGET against an upstream HTTP server, or NTP from
`pool.ntp.org`) the host has to act as a NAT gateway.

#### macOS

```sh
# Enable IP forwarding.
sudo sysctl -w net.inet.ip.forwarding=1

# NAT outbound traffic that came in on feth1 to the
# physical interface (en0 wifi or en1 ethernet -- adjust).
echo 'nat on en0 from 192.168.7.0/24 to any -> (en0)' | \
    sudo pfctl -ef -
```

This is non-persistent.  The same rule can be put in
`/etc/pf.anchors/sprinter` and loaded at boot via
`/etc/pf.conf`; see `man pfctl`.  System Integrity
Protection sometimes blocks pf in custom configurations,
in which case dropping back to local-only services is the
safer path.

The Sprinter's default route must point at `192.168.7.1`
(set by IFUP/DHCP automatically when dnsmasq advertises
option 3).

#### Linux

```sh
sudo sysctl -w net.ipv4.ip_forward=1

# Replace eth0 with your real outbound interface
# (e.g. wlan0).
sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 \
    -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i veth1 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o veth1 \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Persistent setup: drop the rules into `iptables-save` /
`netplan` / `systemd-networkd` depending on the distro.

#### Windows

In the Network Connections control panel, right-click the
real adapter (Wi-Fi or Ethernet), open Properties ->
Sharing, tick **Allow other network users to connect
through this computer's Internet connection**, and pick
the loopback adapter as the home network.  This enables
the built-in **Internet Connection Sharing (ICS)** which
implements NAT + a bundled DHCP server.  Note that ICS
sometimes hard-codes `192.168.137.1/24` for the shared
side -- adjust `NET.CFG` and dnsmasq to match, or disable
the ICS DHCP and use your own dnsmasq.

If you're using WSL2 instead, NAT is handled by the WSL2
virtual switch; the Linux instructions inside WSL2 are
sufficient.

### Sanity checklist

After bringing the test stand up, verify in this order:

1. `ifconfig feth1` (or equivalent) shows `192.168.7.1`.
2. From the host: `ping 192.168.7.1` succeeds.
3. From MAME: `PING 192.168.7.1` (after `NETCFG -i; IFUP`)
   succeeds.
4. Host service started, e.g. `python3 -m http.server`
   prints "Serving HTTP on 192.168.7.1 port 80".
5. Sprinter utility runs: `WGET http://192.168.7.1/test.txt`
   prints `Done. NN bytes received.`

If any step fails, the issue is at that layer (interface
configuration / pcap permission / firewall / utility
itself).  Most surprises in practice come from `pcap`
permissions and from `dnsmasq` colliding with the system
resolver -- `--listen-address=192.168.7.1
--bind-interfaces` plus `--no-resolv` defuses that on
macOS.

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
