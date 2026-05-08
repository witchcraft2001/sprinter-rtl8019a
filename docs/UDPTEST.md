# UDPTEST.EXE

Sends a fixed 16-byte payload (`SPRINTER UDPTEST`) to the given
host:port and waits for an echo reply.  Useful for smoke-testing
UDP through a host-side `udp_echo.py` (see `tools/dev/`).

## Usage

```
UDPTEST host port
UDPTEST /?
```

| Option | Meaning                            |
|--------|------------------------------------|
| `host` | Destination IPv4 or hostname       |
| `port` | Destination UDP port (1..65535)    |

## Example

```
RTL8019AS UDPTEST v0.2

Sending UDP to 192.168.7.1:7777 from 192.168.7.5
Reply: len=16 data=SPRINTER UDPTEST
RESULT OK
```

Custom payload and a `-l` size flag are planned for a later
iteration.

## Exit codes

| Code | Meaning                       |
|------|-------------------------------|
| 0    | OK                            |
| 1    | Usage                         |
| 2    | RTL8019AS not detected        |
| 3    | ARP / UDP timeout             |
| 4    | Config                        |
