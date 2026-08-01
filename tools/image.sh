#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v mformat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
  echo "Error: mtools is required (mformat and mcopy were not found)." >&2
  exit 1
fi
if ! command -v iconv >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
  echo "Error: iconv and perl are required to create CP866 plain-text documentation." >&2
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
  local upper_ext source_ext rendered dos_text encoded

  if [ ! -f "$src" ]; then
    echo "Warning: $src not found, skipping" >&2
    return
  fi

  upper_ext="${dest##*.}"
  upper_ext="$(printf '%s' "$upper_ext" | tr '[:lower:]' '[:upper:]')"

  if is_text_ext "$upper_ext"; then
    rendered="$(mktemp)"
    dos_text="$(mktemp)"
    encoded="$(mktemp)"
    source_ext="${src##*.}"
    source_ext="$(printf '%s' "$source_ext" | tr '[:lower:]' '[:upper:]')"
    if [ "$source_ext" = "MD" ]; then
      perl "$script_dir/markdown_to_text.pl" "$src" > "$rendered"
    else
      cp "$src" "$rendered"
    fi
    LC_ALL=C awk 'BEGIN{ORS="\r\n"} {sub(/\r$/, ""); print}' "$rendered" > "$dos_text"
    if ! iconv -f UTF-8 -t CP866 "$dos_text" > "$encoded"; then
      echo "Error: $src contains characters that cannot be encoded as CP866." >&2
      rm -f "$rendered" "$dos_text" "$encoded"
      exit 1
    fi
    mcopy -i "$image_path" -o "$encoded" "::$dest"
    rm -f "$rendered" "$dos_text" "$encoded"
  else
    mcopy -i "$image_path" -o "$src" "::$dest"
  fi
}

for app in "${BUILD_APPS[@]}"; do
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$repo_root/build/$upper.EXE" "$upper.EXE"
done

# The floppy image carries everything, including the diagnostics and the
# experimental UNET DLL that the ZIP omits: this image is the test stand.
# .DLL is binary, so copy_to_image_root moves it byte for byte.
for dll in ${BUILD_DLLS[@]+"${BUILD_DLLS[@]}"}; do
  upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$repo_root/build/$upper.DLL" "$upper.DLL"
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
