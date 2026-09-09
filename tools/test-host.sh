#!/usr/bin/env bash
# Host-side test gate: syntax-check every harness/test script, verify the
# vendored Z80 core's integrity, build the project, run the actual-EXE test
# suites, and check for a few packaging-hygiene mistakes.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

required_tools=(sjasmplus node python3)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool not found in PATH: $tool" >&2
    exit 1
  fi
  echo "Found $tool: $(command -v "$tool")"
done

bash -n "$script_dir/artifacts.sh" "$script_dir/build.sh" "$script_dir/image.sh" \
  "$script_dir/package.sh" "$script_dir/test-host.sh" "$script_dir/dev/real_hw_prep.sh"

node --check "$script_dir/exe-harness/Z80core.js"
node --check "$script_dir/exe-harness/rtl8019-model.js"
node --check "$script_dir/exe-harness/net-builders.js"
node --check "$script_dir/exe-harness/harness.js"
node --check "$script_dir/exe-harness/run.js"
node --check "$script_dir/exe-harness/test-util.js"
node --check "$script_dir/test-exe-harness.js"
node --check "$script_dir/test-exe-net.js"
node --check "$script_dir/test-exe-tcp.js"
node --check "$script_dir/test-exe-dll.js"

# Every dev script, not a hand-kept subset: the responders are edited as
# often as the tests that use them, and a syntax error in one only shows
# up mid-session on the test stand otherwise.
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir"/dev/*.py

# Integrity: the vendored Z80 interpreter must match the pinned checksum in
# THIRD_PARTY.md. A drift here means someone edited or replaced the file
# without updating the pin -- fail loudly instead of silently trusting it.
pinned_sha="$(grep -A1 '^```$' "$repo_root/THIRD_PARTY.md" | grep -oE '^[0-9a-f]{64}' | head -n1)"
actual_sha="$(shasum -a 256 "$script_dir/exe-harness/Z80core.js" | awk '{print $1}')"
if [ -z "$pinned_sha" ]; then
  echo "Error: could not find a pinned SHA-256 in THIRD_PARTY.md" >&2
  exit 1
fi
if [ "$pinned_sha" != "$actual_sha" ]; then
  echo "Error: tools/exe-harness/Z80core.js does not match the pinned SHA-256 in THIRD_PARTY.md" >&2
  echo "  pinned: $pinned_sha" >&2
  echo "  actual: $actual_sha" >&2
  exit 1
fi
echo "Z80core.js checksum OK ($actual_sha)"

# Hygiene: tools/ must never leak into the shipped ZIP/image manifests.
if grep -E "exe-harness|test-exe-|test-host\.sh" "$script_dir/artifacts.sh" >/dev/null 2>&1; then
  echo "Error: the host test harness must not appear in tools/artifacts.sh DIST arrays" >&2
  exit 1
fi

"$script_dir/build.sh"
node "$script_dir/test-exe-harness.js"
node "$script_dir/test-exe-net.js"
node "$script_dir/test-exe-tcp.js"
node "$script_dir/test-exe-dll.js"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/dev" \
  python3 "$script_dir/dev/test_unettest_tcp_probe.py"

echo "Host tests passed"
