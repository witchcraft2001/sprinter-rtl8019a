# FTP.EXE

Plain FTP client.  Always uses passive mode (PASV).  Four
modes: file download (default), file upload (`PUT` verb),
verbose directory listing (`-l`), and terse name-only listing
(`-n`).

## Usage

```
FTP host[:port] filename  [-u user] [-p pass] [-o output] [-y|-f] [-r] [-d]  (download)
FTP host[:port] PUT local [-u user] [-p pass] [-o remote-name]          (upload)
FTP host[:port] [path] -l [-u user] [-p pass]                           (LIST)
FTP host[:port] [path] -n [-u user] [-p pass]                           (NLST)
FTP /?
```

| Option       | Meaning                                            |
|--------------|----------------------------------------------------|
| `host[:port]`| FTP server IPv4 or hostname; control port defaults |
|              | to 21 (`FTP srv:2121 file.bin`).                   |
| `filename`   | Remote file to RETR (paths allowed: `/pub/foo.zip`)|
| `PUT local`  | Switches to upload mode; `local` is the on-disk    |
|              | source file (path-aware, e.g. `test\foo.zip`).     |
| `path`       | Remote directory to list.  Without `-l` / `-n`     |
|              | ignored.                                           |
| `-l`         | LIST mode (verbose, "ls -l" style with metadata).  |
|              | Without a path argument lists the server's CWD     |
|              | after login.                                       |
| `-n`         | NLST mode (terse, just filenames -- one per line). |
|              | Useful for scripting (parse with batch loops).     |
| `-u user`    | FTP username (default `anonymous`)                 |
| `-p pass`    | FTP password (default `anonymous@`; empty when     |
|              | `-u` is given without `-p`)                        |
| `-o name`    | GET: alternate local output filename (path-aware). |
|              | Without `-o`, the local file is the basename of    |
|              | the remote path -- `FTP host pub/foo.zip` saves    |
|              | as `foo.zip`, not into a non-existent local        |
|              | `pub\` directory.                                  |
|              | PUT: alternate name on the server (overrides STOR  |
|              | argument).  Without `-o` the STOR argument is the  |
|              | basename of the local path -- `PUT C:\docs\a.txt`  |
|              | sends `STOR a.txt`, not `STOR C:\docs\a.txt`.      |
|              | The GET form also supports a directory prefix per  |
|              | "Output paths" in HOWTO.TXT.                       |
| `-y`, `-f`   | Overwrite local file without prompt (GET only).    |
|              | Without `-y`/`-f`/`-r`, an existing local file     |
|              | prompts `Overwrite/Resume/Cancel [O/R/C]` (Y and N |
|              | still work as overwrite / cancel).                 |
| `-r`         | Resume a GET: reopen the local file, append, and   |
|              | send `REST <size>` so the server skips what is     |
|              | already on disk.  Fails with a hint if the server  |
|              | rejects REST.  Ignored for PUT and listings.       |
| `-d`         | Dot progress: print one `.` per 8 KB flush instead |
|              | of the in-place `<done>KB / <total>KB` counter.    |
|              | The counter is repainted through the DSS console,  |
|              | which competes with the transfer; run the same     |
|              | transfer with and without `-d` to measure the cost.|

## Login flow

1. `USER <user>`.
2. If the server replies 2xx, login is complete (some servers
   accept `USER` alone).  If 3xx, send `PASS <pass>` and expect
   2xx.  Anything else exits with `B=3`.
3. `TYPE I` (binary).
4. `PASV` -- parse the data-port tuple.

## Examples

Download:

```
FTP 192.168.7.1 IM2.TXT -y
RTL8019AS FTP v0.2.16
Resolved 192.168.7.1 -> 192.168.7.1
Connecting...ok.
220 pyftpdlib 2.2.0 ready.
331 Username ok, send password.
230 Login successful.
200 Type set to: Binary.
227 Entering passive mode (192,168,7,1,226,68).
Data endpoint: 192.168.7.1:57924
Opening data connection...
125 Data connection already open. Transfer starting.
.................................................
226 Transfer complete.
Done. 389579 bytes received.
  389579 bytes in 7 sec, 54 KB/s
221 Goodbye.
RESULT OK
```

Upload (`PUT`):

```
FTP 192.168.7.1 PUT BOOT.BIN -u alice -p secret
RTL8019AS FTP v0.2.16
...
227 Entering passive mode (192,168,7,1,226,99).
Opening data connection...
125 Data connection already open. Transfer starting.
.....
226 Transfer complete.
Done. 32768 bytes sent.
  32768 bytes in 1 sec, 32 KB/s
221 Goodbye.
RESULT OK
```

Verbose listing (`-l`):

```
FTP 192.168.7.1 -l -u alice -p secret
RTL8019AS FTP v0.2.16
...
227 Entering passive mode (192,168,7,1,226,68).
Opening data connection...
125 Data connection already open. Transfer starting.
-rw-r--r--   1 root  wheel    11573 May  6 15:28 fformat.txt
-rw-r--r--   1 root  wheel     2048 May  6 15:28 2k.bin
-rw-r--r--   1 root  wheel    57344 May  6 15:28 56k.bin
-rw-r--r--   1 root  wheel   389579 May  6 15:28 im2.txt
226 Transfer complete.
221 Goodbye.
RESULT OK
```

Terse listing (`-n`, NLST -- just filenames):

```
FTP 192.168.7.1 -n
RTL8019AS FTP v0.2.16
...
fformat.txt
2k.bin
56k.bin
im2.txt
226 Transfer complete.
221 Goodbye.
RESULT OK
```

Listing data is streamed straight to the console (no local file
is opened); progress dots are not emitted.

## If a transfer stalls and restarts repeatedly

This TCP implementation keeps no out-of-order queue: a segment arriving
after a gap is discarded, so losing one segment costs every byte the
server sent after it plus a full retransmission timeout.  A path that
drops the occasional frame therefore does not merely slow down, it
crawls -- the server's backoff grows and the transfer can end on
`[E] data recv failed, code 0x02`.

The `ovw` field on that line says where the loss is:

| `ovw`      | Meaning                                                  |
|------------|----------------------------------------------------------|
| non-zero   | The card's own receive ring overflowed -- the machine is |
|            | not draining fast enough.  Recovery ran; frames were lost.|
| `0x00`     | The frames never reached the card.  The loss is upstream |
|            | of it -- on the wire, or in the host path of an emulator. |

The first case (`ovw` non-zero) is what a real card shows when the server
fills the advertised receive window faster than the Z80 drains the ring,
typically while an 8 KB block is being written to disk.  The direct client
advertises a two-segment (2920-byte) window at MSS 1460 for exactly this
reason: two maximum frames occupy 12 of the ring's 25 usable pages, leaving
room for a stray broadcast and the flush latency.  Advertising three
segments (the earlier value) filled 18 of 25 and overflowed under that
load.  The window is the lever here, not the segment size -- MSS 1460 keeps
the per-byte receive cost, and therefore the throughput, unchanged.

The second case (`ovw 0x00`) has been seen under MAME, whose host capture
path can drop frames that `tcpdump` on the same interface still shows.
That is not a property of the card or of this stack: driven straight into
the NIC the same transfer completes byte-perfect.  Where that host cannot
be fixed, rebuild with `USE_TCP_RX_SMALL`, which drops the receive geometry
to MSS 536 with a five-segment window; smaller frames are serviced faster
and survive such a path, at roughly a third of the throughput.

## Exit codes

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| 0    | OK                                                       |
| 1    | Usage                                                    |
| 2    | RTL8019AS not detected                                   |
| 3    | Network unreachable (ARP / TCP connect / control-channel |
|      | recv timeout / DNS)                                      |
| 4    | Config                                                   |
| 5    | Local file create / write / close failure                |
| 6    | Server rejected: 5xx / 4xx control reply (incl. 550),    |
|      | malformed PASV reply, login failure                      |
| 7    | Cancelled by user (Esc / Ctrl+C)                         |
