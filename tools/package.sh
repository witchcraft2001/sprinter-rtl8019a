#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: zip is not installed or not in PATH" >&2
  exit 1
fi
if ! command -v iconv >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
  echo "Error: iconv and perl are required to create CP866 plain-text documentation." >&2
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
  local src="$1" dest="$2" upper_ext source_ext rendered dos_text
  upper_ext="${dest##*.}"
  upper_ext="$(printf '%s' "$upper_ext" | tr '[:lower:]' '[:upper:]')"
  if is_text_ext "$upper_ext"; then
    rendered="$(mktemp)"
    dos_text="$(mktemp)"
    source_ext="${src##*.}"
    source_ext="$(printf '%s' "$source_ext" | tr '[:lower:]' '[:upper:]')"
    if [ "$source_ext" = "MD" ]; then
      perl "$script_dir/markdown_to_text.pl" "$src" > "$rendered"
    else
      cp "$src" "$rendered"
    fi
    LC_ALL=C awk 'BEGIN{ORS="\r\n"} {sub(/\r$/, ""); print}' "$rendered" > "$dos_text"
    if ! iconv -f UTF-8 -t CP866 "$dos_text" > "$dest"; then
      echo "Error: $src contains characters that cannot be encoded as CP866." >&2
      rm -f "$rendered" "$dos_text" "$dest"
      exit 1
    fi
    rm -f "$rendered" "$dos_text"
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

# Diagnostics and experimental DLLs are built and put on the floppy image
# but kept out of the release ZIP.  The ZIP is the supported kit; a
# half-validated component there invites bug reports against the whole
# package.  See ZIP_EXCLUDE_* in tools/artifacts.sh.
is_excluded() {
  local needle="$1"
  shift
  # A bare "$@" under `set -u` with an empty array is an error on the
  # bash 3.2 that ships with macOS, so guard on the count first.
  [ "$#" -eq 0 ] && return 1
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

for app in "${BUILD_APPS[@]}"; do
  if is_excluded "$app" ${ZIP_EXCLUDE_APPS[@]+"${ZIP_EXCLUDE_APPS[@]}"}; then
    continue
  fi
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  if [ -f "$exe" ]; then
    cp "$exe" "$package_root/$upper.EXE"
  else
    echo "Warning: build/$upper.EXE not found, skipping" >&2
  fi
done

for dll in ${BUILD_DLLS[@]+"${BUILD_DLLS[@]}"}; do
  if is_excluded "$dll" ${ZIP_EXCLUDE_DLLS[@]+"${ZIP_EXCLUDE_DLLS[@]}"}; then
    continue
  fi
  upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
  dll_path="$repo_root/build/$upper.DLL"
  if [ -f "$dll_path" ]; then
    cp "$dll_path" "$package_root/$upper.DLL"
  else
    echo "Warning: build/$upper.DLL not found, skipping" >&2
  fi
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  if is_excluded "$rel_path" ${ZIP_EXCLUDE_DOC_FILES[@]+"${ZIP_EXCLUDE_DOC_FILES[@]}"}; then
    continue
  fi
  copy_doc "$rel_path"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  copy_simple "$rel_path"
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  copy_simple "$rel_path"
done

rm -f "$zip_path"
# Keep the archive flat, exactly like the FAT image.  A long top-level
# directory named after DIST_NAME would itself violate the target's strict
# 8.3 namespace when the zip is unpacked directly onto the Sprinter disk.
cd "$package_root"
zip -qr "$zip_path" .

echo "Created $zip_path"
