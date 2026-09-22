# IFUP.EXE

Brings the network interface up.  Behaviour depends on
`NET_IP_SRC`:

- **STATIC**: just verifies that `NET_IP` and `NET_MAC` are set
  and prints the assigned address.
- **DHCP**: runs the full DHCP cycle (DISCOVER -> OFFER ->
  REQUEST -> ACK), then `SETENV`s `NET_IP`, `NET_MASK`, `NET_GW`,
  `NET_DNS1`, `NET_DNS2`, `NET_DHCP_SRV`, `NET_LEASE_SEC`.

If `NET_RTL_TYPE` is absent, IFUP first probes the `2000h` and `4000h`
packet-RAM windows. An unambiguous result is published as `NE1000` or
`NE2000`; ambiguous/unknown results use the NE2000 fallback without
publishing a type. A remote-DMA failure is fatal: IFUP prints `[E07]` (or
`[E08]` if the controller no longer responds), exits 3, and does not set
`NET=RTL`.

## Usage

```
IFUP            bring interface up per NET_IP_SRC
IFUP /?         help
```

## Example (DHCP)

```
RTL8019AS IFUP v0.2.16

DHCP: sending DISCOVER...
DHCP: got OFFER 192.168.7.100 (server 192.168.7.1)
DHCP: lease IP=192.168.7.100 (server 192.168.7.1, lease 3600 s)
RESULT OK
```

Esc and Ctrl+C abort the DHCP wait.

`IFUP -r` (renew) and `IFUP -d` (release) are planned for a
later iteration.

## Exit codes

| Code | Meaning                                              |
|------|------------------------------------------------------|
| 0    | OK                                                   |
| 1    | Usage                                                |
| 2    | RTL8019AS not detected                               |
| 3    | NIC/DMA failure, DHCP timeout, or cancel             |
| 4    | Config (`NET_MAC` missing, or `NET_IP` missing in    |
|      | static mode)                                         |
