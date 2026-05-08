# ARP.EXE

Single ARP probe.  Resolves an IPv4 to a MAC and prints it.

## Usage

```
ARP target
ARP /?
```

`target` is the destination IPv4 (e.g. `192.168.7.1`).

## Example

```
RTL8019AS ARP v0.2

ARPING 192.168.7.1 from 192.168.7.5 (02:80:19:11:22:33)
Reply from 192.168.7.1: 66:65:74:68:00:01
RESULT OK
```

The current ARP cache is 1..4 entries inside the running utility
and is not persisted; an "arp -a" listing is not available in v0.2.

## Exit codes

| Code | Meaning                       |
|------|-------------------------------|
| 0    | OK                            |
| 1    | Usage                         |
| 2    | RTL8019AS not detected        |
| 3    | ARP timeout / cancel          |
| 4    | Config                        |
