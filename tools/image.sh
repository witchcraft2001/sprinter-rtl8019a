#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v mformat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
  echo "Error: mtools is required (mformat and mcopy were not found)." >&2
  exit 1
fi

"$script_dir/build.sh"

image_path="${1:-$repo_root/distr/$DIST_NAME.img}"

mkdir -p "$(dirname "$image_path")"
rm -f "$image_path"

mformat -C -i "$image_path" -f 1440 ::

# DOS expects CRLF in text files. Convert LF -> CRLF for known text
# extensions when copying to the FAT image; binaries pass through unchanged.
is_text_ext() {
  case "$1" in
    TXT|CFG|BAT|INI|INF|MD) return 0 ;;
    *) return 1 ;;
  esac
}

copy_to_image_root() {
  local src="$1"
  local dest="$2"
  local upper_ext

  if [ ! -f "$src" ]; then
    echo "Warning: $src not found, skipping" >&2
    return
  fi

  upper_ext="${dest##*.}"
  upper_ext="$(printf '%s' "$upper_ext" | tr '[:lower:]' '[:upper:]')"

  if is_text_ext "$upper_ext"; then
    # The DSS text viewer renders bytes through CP866; UTF-8 multi-byte
    # sequences come out as mojibake. Until an explicit transcoding step
    # is added, shipped text files must be 7-bit ASCII.
    if LC_ALL=C grep -lP '[^\x00-\x7F]' "$src" >/dev/null 2>&1; then
      echo "Error: $src contains non-ASCII bytes; convert to ASCII (or add CP866 transcoding) before shipping." >&2
      LC_ALL=C grep -nP '[^\x00-\x7F]' "$src" >&2 || true
      exit 1
    fi
    local tmp
    tmp="$(mktemp)"
    awk 'BEGIN{ORS="\r\n"} {sub(/\r$/, ""); print}' "$src" > "$tmp"
    mcopy -i "$image_path" -o "$tmp" "::$dest"
    rm -f "$tmp"
  else
    mcopy -i "$image_path" -o "$src" "::$dest"
  fi
}

for app in "${BUILD_APPS[@]}"; do
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$repo_root/build/$upper.EXE" "$upper.EXE"
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"

  case "$upper_base" in
    *.MD) image_name="${upper_base%.MD}.TXT" ;;
    *) image_name="$upper_base" ;;
  esac

  copy_to_image_root "$src" "$image_name"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$src" "$upper_base"
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  image_name="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$src" "$image_name"
done

echo "Created FAT12 image: $image_path"
