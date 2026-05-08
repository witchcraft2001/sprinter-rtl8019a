# TFTP.EXE

TFTP client, octet mode (RFC 1350) with RFC 2348 `blksize`
option negotiation.  Only `GET` is implemented in v0.4.

## Usage

```
TFTP host GET filename [-o output] [-y]
TFTP /?
```

| Option       | Meaning                                            |
|--------------|----------------------------------------------------|
| `host`       | TFTP server IPv4 or hostname                       |
| `GET`        | Fetch operation (only mode supported)              |
| `filename`   | Remote file (relative to the server's TFTP root)   |
| `-o file`    | Local output (default = remote name; supports      |
|              | directory prefix per "Output paths" in HOWTO.TXT)  |
| `-y`         | Overwrite local file without prompt                |

The RRQ asks for `blksize=1428` (Ethernet MTU minus the IP /
UDP / TFTP headers); a server that ignores the option falls
back to RFC 1350 512-byte blocks transparently.  Bigger
blocks reduce the round-trip count by ~2.8x on large files.

Disk I/O is buffered: TFTP coalesces incoming blocks into an
8 KB buffer and writes that to disk in one `DSS_WRITE`,
printing one `.` per buffer flush as a progress indicator.

## Example

```
RTL8019AS TFTP v0.4

GET IM2.TXT from 192.168.7.1
[F0] OACK blksize=1428
.................................................
Done. 389579 bytes received.
  389579 bytes in 5 sec, 76 KB/s
RESULT OK
```

Cancelling with Esc/Ctrl+C closes the partial output file.

`PUT` and a `windowsize` option (RFC 7440) for further
speed-up are tracked as follow-ups; not in v0.4.

## Exit codes

| Code | Meaning                                              |
|------|------------------------------------------------------|
| 0    | OK                                                   |
| 1    | Usage (including `PUT`)                              |
| 2    | RTL8019AS not detected                               |
| 3    | ARP / TFTP timeout / server error                    |
| 4    | Config                                               |
| 5    | File create / write failure                          |
