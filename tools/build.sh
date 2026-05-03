#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if [ "${#BUILD_APPS[@]}" -eq 0 ]; then
  echo "No DSS applications are listed in tools/artifacts.sh yet."
  exit 0
fi

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is not installed or not in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

built=0
for app in "${BUILD_APPS[@]}"; do
  src="$repo_root/src/apps/$app.asm"
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  lst="$repo_root/build/$upper.lst"

  if [ ! -f "$src" ]; then
    echo "Warning: $src not found, skipping $upper.EXE" >&2
    continue
  fi

  sjasmplus --nologo --fullpath \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$lst" --raw="$exe" "$src"
  echo "Built $exe"
  built=$((built + 1))
done

if [ "$built" -eq 0 ]; then
  echo "No DSS applications were built. Add sources under src/apps/ and list them in tools/artifacts.sh."
fi
