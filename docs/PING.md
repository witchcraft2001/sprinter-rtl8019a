# PING.EXE

Sends ICMP echo requests, prints replies and per-run statistics.

## Usage

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
| `target` | Destination IPv4 or hostname.                          |

`-t` and `-n` are mutually compatible: when `-t` is supplied, the
count from `-n` is ignored and the loop continues until the user
cancels.

## Example

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

Timing resolution on the Sprinter Z80 is below 1 ms for LAN
exchanges, so all replies show `time<1ms`.

## Exit codes

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| 0    | At least one reply was received                          |
| 1    | Usage                                                    |
| 2    | RTL8019AS not detected                                   |
| 3    | All requests timed out / cancelled                       |
| 4    | Config                                                   |
