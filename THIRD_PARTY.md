# Third-party code

This repository is otherwise original work. One file under `tools/` (a
developer-only, non-shipped directory -- see `tools/artifacts.sh`) embeds a
third-party library:

## Z80core.js

- Path: `tools/exe-harness/Z80core.js`
- Author: Molly Howell
- License: MIT (see `tools/exe-harness/LICENSE.Z80core`)
- Purpose: Z80 CPU interpreter used by the host-side EXE test harness
  (`tools/exe-harness/`) to execute real built Sprinter DSS `.EXE` files
  under Node.js for automated testing. It never ships to end users --
  `tools/` is excluded from both the ZIP and the floppy image manifests.
- Integrity: `tools/test-host.sh` verifies the file's SHA-256 checksum on
  every run and fails the build if it drifts from the pinned value below.

```
44a0398fdf763aca6cd3608777f4b30aa53ceb4d0ec2f7234422ceb44980def0  tools/exe-harness/Z80core.js
```

To update Z80core.js, replace the file, recompute the checksum
(`shasum -a 256 tools/exe-harness/Z80core.js`), and update the pinned value
in both this file and `tools/test-host.sh`.
