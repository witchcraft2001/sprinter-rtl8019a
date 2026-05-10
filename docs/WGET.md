# WGET.EXE

Plain HTTP/1.0 downloader with redirect following.  No HTTPS.

## Usage

```
WGET url [-o output] [-y]
WGET /?
```

| Option     | Meaning                                              |
|------------|------------------------------------------------------|
| `url`      | `http://host[:port][/path]`.  The `http://` is       |
|            | optional but recommended for clarity.                |
| `-o file`  | Local output (default: basename derived from URL     |
|            | path; supports directory prefix per "Output paths"   |
|            | in HOWTO.TXT).                                       |
| `-y`       | Overwrite local file without prompt.                 |

## Behaviour

- Status-aware.  2xx is success.  3xx is followed via the
  `Location:` response header (cap 5 hops); 3xx redirects whose
  `Location` points at `https://` are reported and the transfer
  fails with a clear "no TLS" error.  4xx / 5xx prints
  `[E] HTTP/1.x NNN <reason>` and exits B=3.
- The output file is opened up front; if the final hop is not
  2xx the partial file is `DELETE`d before exiting so batch
  scripts don't see stale 0-byte / error-page files.
- Disk I/O is buffered: 8 KB write coalescing buffer, one `.`
  printed per flush.
- End-of-run summary prints byte count and KB/s (or B/s for
  low-rate transfers) using DSS clock deltas.

## Examples

Direct download:

```
RTL8019AS WGET v0.2.2
Resolved tr-dos.ru -> 188.127.239.141 port 80
Connecting to 188.127.239.141 port 80...ESTABLISHED.
.....
Done. 33005 bytes received.
  33005 bytes in 1 sec, 32 KB/s
RESULT OK
```

Following a redirect (`http://`->`http://`):

```
WGET http://192.168.7.1:8080/redir-abs
RTL8019AS WGET v0.2.2
Resolved 192.168.7.1 -> 192.168.7.1 port 8080
Connecting to 192.168.7.1 port 8080...ESTABLISHED.
Redirect: HTTP/1.0 302 Found
Resolved 192.168.7.1 -> 192.168.7.1 port 80
Connecting to 192.168.7.1 port 80...ESTABLISHED.
.....
Done. 33005 bytes received.
  33005 bytes in 1 sec, 32 KB/s
RESULT OK
```

Cancelling with Esc/Ctrl+C closes and deletes the partial output
file.

## Exit codes

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| 0    | OK                                                       |
| 1    | Usage (bad URL, missing argument)                        |
| 2    | RTL8019AS not detected                                   |
| 3    | Network error / HTTP 4xx-5xx / `https://` redirect /     |
|      | too many redirects                                       |
| 4    | Config                                                   |
| 5    | File create / write failure                              |
