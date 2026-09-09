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

# --- UNET ABI sync gate ------------------------------------------------------
# src/include/unet.inc is a byte-identical mirror of the frozen contract that
# lives in the sprinter_wifi project; both backends MUST compile against the
# same function numbers and error codes. A silent divergence between the two
# copies is the worst failure mode this design has, so fail loudly when the
# reference is present and differs. Skipped when the sibling is not checked out.
abi_ref="${UNET_ABI_SRC:-$repo_root/../sprinter_wifi/network}/src/include/unet.inc"
abi_local="$repo_root/src/include/unet.inc"
if [ -f "$abi_ref" ] && [ -f "$abi_local" ]; then
  if ! cmp -s "$abi_ref" "$abi_local"; then
    echo "Error: $abi_local differs from the frozen UNET ABI at $abi_ref" >&2
    diff -u "$abi_ref" "$abi_local" >&2 || true
    exit 1
  fi
fi

# --- libman 1.3 / L1 DLL libraries (built with sprinter-mkdll) ---------------
# The relocatable L1 container and its 32-byte header are produced by
# sprinter-mkdll (the libman builder), which runs sjasmplus twice with origins
# 0x100 apart and diffs the passes to build the relocation bitmap. Prefer an
# installed console script, else run the module straight from the libman source
# tree. A missing tool is a non-fatal skip so the repo stays buildable without
# libman checked out.
if [ "${#BUILD_DLLS[@]}" -gt 0 ]; then
  mkdll_cmd=()
  if command -v sprinter-mkdll >/dev/null 2>&1; then
    mkdll_cmd=(sprinter-mkdll)
  else
    libman_src="${UNET_LIBMAN_SRC:-$repo_root/../sources/libman/src}"
    if [ -f "$libman_src/sprinter_mkdll/cli.py" ]; then
      mkdll_cmd=(env "PYTHONPATH=$libman_src" python3 -m sprinter_mkdll.cli)
    fi
  fi

  if [ "${#mkdll_cmd[@]}" -eq 0 ]; then
    echo "Warning: sprinter-mkdll not found (install libman or set UNET_LIBMAN_SRC); skipping DLL build" >&2
  else
    # This repo keeps its version in src/include/version.inc, not a VERSION
    # file.  The L1 numeric header carries only major.minor, while its
    # 15-byte name field carries the complete human-readable package tag.
    package_version="$(sed -n 's/.*PACKAGE_VERSION[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
                      "$repo_root/src/include/version.inc" | head -1)"
    [ -n "$package_version" ] || {
      echo "Error: PACKAGE_VERSION must use major.minor.revision form" >&2
      exit 1
    }
    dll_version="$(sed -n 's/.*PACKAGE_VERSION[[:space:]]*"\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' \
                     "$repo_root/src/include/version.inc" | head -1)"
    [ -n "$dll_version" ] || dll_version="0.1"

    for dll in "${BUILD_DLLS[@]}"; do
      src="$repo_root/src/dll/$dll.asm"
      upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
      out="$repo_root/build/$upper.DLL"

      if [ ! -f "$src" ]; then
        echo "Warning: $src not found, skipping $upper.DLL" >&2
        continue
      fi

      # The L1 name field holds at most 15 bytes and is what l_info reports.
      case "$dll" in
        unetrtl) dll_name="UNETRTL v$package_version" ;;
        *)       dll_name="$upper" ;;
      esac
      if [ "${#dll_name}" -gt 15 ]; then
        echo "Error: L1 text tag '$dll_name' exceeds the 15-byte header field" >&2
        exit 1
      fi

      "${mkdll_cmd[@]}" build "$src" \
        --format l1 --target 1.3 --assembler sjasmplus \
        -I "$repo_root/src/include" -I "$repo_root/src/lib" \
        --name "$dll_name" --version "$dll_version" --no-compress -o "$out"
      "${mkdll_cmd[@]}" verify "$out" --target 1.3
      echo "Built $out"

      # UNETRTL-only: append the WIN0-cold blob (src/dll/unetrtl_cold.asm,
      # RESOLVE/DNS/ARP/PING logic that runs via src/lib/win0cold.asm's
      # MMU-window-0 overlay -- see that file's header) as
      # [2-byte LE length][blob bytes] right after the L1 image.  libman's
      # loader only ever reads the L1 header's own file_size bytes, so this
      # trailing data is inert to every OTHER consumer of the DLL; verified
      # against `sprinter-mkdll verify`/`inspect`, which report it as
      # ordinary trailing_size and still pass.  A missing/failed cold-blob
      # assembly is a hard error, not a silent skip: WIN0COLD.INIT's own
      # best-effort fallback (see its header) is what makes a MISSING blob
      # safe at runtime, but a build that meant to ship one and silently
      # didn't would ship a DLL that always reports RESOLVE/PING NERR_NOTSUP.
      if [ "$dll" = "unetrtl" ]; then
        cold_src="$repo_root/src/dll/unetrtl_cold.asm"
        if [ -f "$cold_src" ]; then
          cold_bin="$repo_root/build/unetrtl_cold.bin"
          sjasmplus -I "$repo_root/src/include" -I "$repo_root/src/lib" \
            "--raw=$cold_bin" "$cold_src"
          python3 - "$out" "$cold_bin" <<'PYEOF'
import struct, sys
out_path, cold_path = sys.argv[1], sys.argv[2]
with open(cold_path, "rb") as f:
    cold = f.read()
with open(out_path, "ab") as f:
    f.write(struct.pack("<H", len(cold)))
    f.write(cold)
PYEOF
          "${mkdll_cmd[@]}" verify "$out" --target 1.3
          cold_size="$(wc -c < "$cold_bin" | tr -d ' ')"
          echo "Appended $cold_size-byte cold blob to $out"
          rm -f "$cold_bin"
        fi
      fi

      # Keep a ready-to-use runtime DLL at the repository root.  Consumers
      # can take this file directly; it is regenerated only after the L1
      # container has passed verification above.
      published="$repo_root/$upper.DLL"
      if ! cmp -s "$out" "$published" 2>/dev/null; then
        cp "$out" "$published"
        echo "Published $published"
      fi
    done
  fi
fi
