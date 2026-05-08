# NETCFG.EXE

Reads `NET.CFG` and publishes parsed values into DSS environment
variables, or displays them.  See `HOWTO.TXT` for the full list of
recognised `NET.CFG` keys and the resulting env vars.

## Usage

```
NETCFG          show current NET_* env values
NETCFG -i       init: load NET.CFG into NET_* env vars
NETCFG -c       check NET.CFG syntax (no env writes)
NETCFG -d       delete all NET_* env vars
NETCFG /?       help (-? -h also accepted)
```

`NETCFG.EXE` is the only utility in the kit that opens `NET.CFG`.
All other utilities read from environment variables only.

## Exit codes

| Code | Meaning                                           |
|------|---------------------------------------------------|
| 0    | OK                                                |
| 1    | Usage                                             |
| 4    | Config error (only with `-i` / `-c`)              |
