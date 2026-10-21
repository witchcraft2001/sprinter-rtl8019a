# Acceptance records

Keep concise Markdown reports here: the tested version and SHA-256,
environment, reproduction commands, results and conclusions. Preserve
useful hardware observations and screenshots that explain a finding.

Raw JSON/TXT/LOG files, packet captures and assembler symbol maps are
generated run outputs. They are not source files or test fixtures and do
not belong in Git. Keep them in ignored `build/evidence/`, or attach them
to the relevant issue/release when a full capture is needed.

The Battleship runner uses `build/evidence/unetrtl` by default:

```sh
python3 tools/dev/run_battleship_n3.py --cases n2
python3 tools/dev/run_battleship_n3.py --evidence build/evidence/my-run
```

Historical reports may mention raw output filenames. Those names identify
local run artifacts; the repository retains the summaries, not the raw
files. Regenerate new outputs with the recorded commands. Required runtime
files such as the package's README.TXT are unrelated to this policy.
