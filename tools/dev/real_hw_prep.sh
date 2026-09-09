#!/bin/bash
# Print the concrete values needed to run docs/UNETRTL_TESTING_HW_RU.md
# against a REAL Sprinter (not MAME): this host's LAN-facing interface,
# its IPv4 address, and the sysctl/bpf reminders that testing has
# tripped over before. Unlike tools/dev/init_interfaces.sh (which builds
# a feth0/feth1 pair + NAT purely for MAME's pcap backend), this host is
# already ON the same physical LAN as the Sprinter -- there is nothing
# to create, only to report.
#
# Usage:
#   ./tools/dev/real_hw_prep.sh              # auto-detect via default route
#   ./tools/dev/real_hw_prep.sh en0          # force a specific interface

set -e

IFACE=${1:-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}
if [[ -z "$IFACE" ]]; then
    echo "Could not auto-detect the LAN interface; pass it as the first arg (e.g. en0)." >&2
    exit 1
fi

IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
if [[ -z "$IP" ]]; then
    echo "Interface '$IFACE' has no IPv4 address (ipconfig getifaddr failed)." >&2
    echo "Pick the interface actually cabled/associated to the Sprinter's LAN." >&2
    ifconfig -l
    exit 1
fi

MASK_HEX=$(ipconfig getoption "$IFACE" subnet_mask 2>/dev/null || true)

echo "== Real-hardware test parameters =="
echo "Host interface:      $IFACE"
echo "Host IPv4:            $IP"
[[ -n "$MASK_HEX" ]] && echo "Host netmask:         $MASK_HEX"
echo
echo "Use these in the Sprinter's NET.CFG (GATEWAY/DNS point at your real"
echo "router, not at this host) and as --bind/--host for tools/dev/*.py."
echo
echo "-- bpf permissions (needed for tcpdump / send_frame.py) --"
if ls -l /dev/bpf0 2>/dev/null | awk '{print $1}' | grep -q 'r..$'; then
    echo "OK: /dev/bpf* already world-readable."
else
    echo "Run:  sudo chmod o+r /dev/bpf*"
fi
echo
echo "-- TCP receive-buffer auto-tuning (only matters for Scenario E, ASYNCSEND) --"
CUR=$(sysctl -n net.inet.tcp.doautorcvbuf 2>/dev/null || echo "?")
echo "net.inet.tcp.doautorcvbuf = $CUR"
if [[ "$CUR" == "1" ]]; then
    echo "Before unettest_asyncsend_stall.py: sudo sysctl -w net.inet.tcp.doautorcvbuf=0"
    echo "Afterward, restore it:              sudo sysctl -w net.inet.tcp.doautorcvbuf=1"
fi
echo
echo "-- Suggested ports (avoid real LAN service collisions; override with --port) --"
echo "TCP echo (Scenario A):        18080"
echo "UDP echo (Scenario B):        17777"
echo "MULTICHAN control/data (C):   19099 / 19100"
echo "LISTEN target (Scenario D):   19000"
echo "ASYNCSEND stall (Scenario E): 18081"
echo
echo "Example invocations (copy, then adjust the port if it collides):"
echo "  sudo python3 tools/dev/unettest_tcp_probe.py --bind $IP --port 18080"
echo "  sudo python3 tools/dev/udp_echo.py --bind $IP --port 17777"
echo "  python3 tools/dev/dual_server.py --host $IP --control-port 19099 --data-port 19100"
echo "  python3 tools/dev/unettest_listen_client.py --host $IP --port 19000"
echo "  sudo python3 tools/dev/unettest_listen_capture.py --iface $IFACE --host $IP --port 19000"
echo "  python3 tools/dev/unettest_asyncsend_stall.py --bind $IP --port 18081 --rcvbuf 700 --stall 1"
