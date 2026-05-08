#!/usr/bin/env bash

# Central artifact manifest for build, package and floppy image scripts.
# When a new DSS utility, document, config template or bundled data file
# becomes part of the network package, add it here first.

DIST_NAME="sprinter-rtl8019a"
DIST_DIR_NAME="SPRTL"

# DSS application entry points. Each item maps to src/apps/<name>.asm and
# build/<UPPERCASE_NAME>.EXE. Add apps here only when their source is present.
# Stage order from sprinter_rtl8019_soft.md:
#   hello -> nicinfo -> nicram -> niclb -> nictx -> nicrx ->
#   ping -> udptest -> tftp -> ntp -> wget -> ftp
BUILD_APPS=(
  hello
  nicinfo
  isaprobe
  nicram
  niclb
  nictx
  nicrx
  arp
  ping
  udptest
  tftp
  netcfg
  ifup
  ntp
  nslookup
  wget
  ftp
)

# Text/documentation files copied to the distribution root.
# docs/MAME_NETWORK.md is intentionally NOT shipped: it is developer-only.
# Per-utility pages are short references; HOWTO.md collects everything
# common (env vars, exit codes, batch examples).  USAGE.md is the index.
DIST_DOC_FILES=(
  README.md
  docs/USAGE.md
  docs/HOWTO.md
  docs/NETCFG.md
  docs/IFUP.md
  docs/ARP.md
  docs/PING.md
  docs/UDPTEST.md
  docs/NSLOOKUP.md
  docs/NTP.md
  docs/WGET.md
  docs/FTP.md
  docs/TFTP.md
  docs/ISAPROBE.md
  LICENSE
)

# Configuration examples copied to the distribution root. Names already in
# 8.3 form so package.sh and image.sh ship them under the same name. The
# user installs NETSMPL.CFG with `REN NETSMPL.CFG NET.CFG` on the device.
DIST_CONFIG_FILES=(
  config/NETSMPL.CFG
)

# Extra files copied to the distribution root. Keep this for small required
# runtime files that are neither docs nor configs.
DIST_EXTRA_FILES=(
)
