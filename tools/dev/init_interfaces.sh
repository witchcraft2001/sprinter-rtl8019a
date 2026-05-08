#!/bin/bash
# Bring up the feth0/feth1 pair used by MAME's pcap-based ISA
# Ethernet emulation, then turn the host into a NAT gateway so
# the Sprinter VM can reach the real internet (needed for HTTP
# redirects, NTP against pool.ntp.org, DNS lookups against
# upstream resolvers, etc.).
#
# feth0 is the side MAME pcaps onto; feth1 holds the host-side
# IP (192.168.7.1) that dnsmasq + the test ftp/tftp servers
# bind to.  The Sprinter sees them as a single 192.168.7.0/24
# subnet with .1 as the gateway.
#
# WAN can be overridden:  ./init_interfaces.sh en1
# Default is the interface the host's default route points at.

set -e

WAN=${1:-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}
if [[ -z "$WAN" ]]; then
    echo "Could not auto-detect WAN interface; pass it as the first arg." >&2
    exit 1
fi
echo "Using WAN interface: $WAN"

# --- feth pair --------------------------------------------------
sudo ifconfig feth0 destroy 2>/dev/null || true
sudo ifconfig feth1 destroy 2>/dev/null || true
sudo ifconfig feth0 create
sudo ifconfig feth1 create
sudo ifconfig feth0 peer feth1
sudo ifconfig feth0 up
sudo ifconfig feth1 inet 192.168.7.1/24 up
sudo chmod o+r /dev/bpf*

# --- host-as-router -------------------------------------------
# IP forwarding so packets that arrive on feth1 (from the
# Sprinter) can leave through $WAN.
sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null

# NAT: rewrite source IP of 192.168.7.0/24 traffic to $WAN's
# address so replies come back through us.  We REPLACE the pf
# ruleset (use an anchor in production setups; this is a dev
# workstation script).
sudo pfctl -ef - <<EOF
nat on $WAN inet from 192.168.7.0/24 to any -> ($WAN)
pass out quick keep state
pass in quick on feth1 keep state
EOF

echo "feth0 / feth1 are up; $WAN is doing NAT for 192.168.7.0/24."
echo "Sprinter side: gateway = 192.168.7.1, dnsmasq + servers run on the host."
