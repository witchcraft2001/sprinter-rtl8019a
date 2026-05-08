# FTP.EXE

Plain FTP client.  Always uses passive mode (PASV) in v0.1.
Two modes: file download (default) and remote directory
listing (`-l`).

## Usage

```
FTP host filename [-u user] [-p pass] [-o output] [-y]   (download)
FTP host [path] -l [-u user] [-p pass]                    (list)
FTP /?
```

| Option       | Meaning                                            |
|--------------|----------------------------------------------------|
| `host`       | FTP server IPv4 or hostname (port 21)              |
| `filename`   | Remote file to RETR (paths allowed: `/pub/foo.zip`)|
| `path`       | Remote directory to LIST.  Without `-l` ignored.   |
| `-l`         | List directory instead of downloading.  Without a  |
|              | path argument lists the server's CWD after login.  |
| `-u user`    | FTP username (default `anonymous`)                 |
| `-p pass`    | FTP password (default `anonymous@`; empty when     |
|              | `-u` is given without `-p`)                        |
| `-o file`    | Local output (download mode only; default = remote |
|              | basename; supports directory prefix per "Output    |
|              | paths" in HOWTO.TXT)                               |
| `-y`         | Overwrite local file without prompt                |

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
RTL8019AS FTP v0.1
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

Listing:

```
FTP 192.168.7.1 -l -u alice -p secret
RTL8019AS FTP v0.1
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

Listing data is streamed straight to the console (no local file
is opened); progress dots are not emitted.

## Exit codes

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| 0    | OK                                                       |
| 1    | Usage                                                    |
| 2    | RTL8019AS not detected                                   |
| 3    | Network / FTP reply error / unsupported reply            |
| 4    | Config                                                   |
| 5    | File create / write failure                              |
