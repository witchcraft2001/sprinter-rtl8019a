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
    # file. The L1 header carries only major.minor.
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
        unetrtl) dll_name="UNET RTL" ;;
        *)       dll_name="$upper" ;;
      esac

      "${mkdll_cmd[@]}" build "$src" \
        --format l1 --target 1.3 --assembler sjasmplus \
        -I "$repo_root/src/include" -I "$repo_root/src/lib" \
        --name "$dll_name" --version "$dll_version" --no-compress -o "$out"
      "${mkdll_cmd[@]}" verify "$out" --target 1.3
      echo "Built $out"
    done
  fi
fi
