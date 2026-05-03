#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: zip is not installed or not in PATH" >&2
  exit 1
fi

# DOS expects CRLF in text files. Convert LF -> CRLF for known text
# extensions when copying to the distribution; binaries pass through
# unchanged. Idempotent for files that already use CRLF.
is_text_ext() {
  case "$1" in
    TXT|CFG|BAT|INI|INF|MD) return 0 ;;
    *) return 1 ;;
  esac
}

copy_with_crlf() {
  local src="$1" dest="$2" upper_ext
  upper_ext="${dest##*.}"
  upper_ext="$(printf '%s' "$upper_ext" | tr '[:lower:]' '[:upper:]')"
  if is_text_ext "$upper_ext"; then
    awk 'BEGIN{ORS="\r\n"} {sub(/\r$/, ""); print}' "$src" > "$dest"
  else
    cp "$src" "$dest"
  fi
}

"$script_dir/build.sh"

package_root="$repo_root/build/package/$DIST_NAME"
zip_path="$repo_root/distr/$DIST_NAME.zip"

mkdir -p "$repo_root/distr" "$repo_root/build/package"
rm -rf "$package_root"
mkdir -p "$package_root"

copy_doc() {
  local rel_path="$1"
  local src="$repo_root/$rel_path"
  local base upper_base image_name

  if [ ! -f "$src" ]; then
    echo "Warning: $rel_path not found, skipping" >&2
    return
  fi

  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"

  case "$upper_base" in
    *.MD) image_name="${upper_base%.MD}.TXT" ;;
    *)    image_name="$upper_base" ;;
  esac

  copy_with_crlf "$src" "$package_root/$image_name"
}

copy_simple() {
  local rel_path="$1"
  local src="$repo_root/$rel_path"
  local base upper_base

  if [ ! -f "$src" ]; then
    echo "Warning: $rel_path not found, skipping" >&2
    return
  fi

  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
  copy_with_crlf "$src" "$package_root/$upper_base"
}

for app in "${BUILD_APPS[@]}"; do
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  if [ -f "$exe" ]; then
    cp "$exe" "$package_root/$upper.EXE"
  else
    echo "Warning: build/$upper.EXE not found, skipping" >&2
  fi
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  copy_doc "$rel_path"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  copy_simple "$rel_path"
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  copy_simple "$rel_path"
done

rm -f "$zip_path"
cd "$repo_root/build/package"
zip -qr "$zip_path" "$DIST_NAME"

echo "Created $zip_path"
