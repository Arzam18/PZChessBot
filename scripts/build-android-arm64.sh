#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" || ! -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
  echo "ERROR: ANDROID_NDK_HOME/ANDROID_NDK_ROOT must point to Android NDK r27c." >&2
  exit 1
fi
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
ANDROID_CXX="$TOOLCHAIN/aarch64-linux-android24-clang++"
OBJDUMP="$TOOLCHAIN/llvm-objdump"
for tool in "$ANDROID_CXX" "$OBJDUMP" "$TOOLCHAIN/llvm-readelf"; do
  [[ -x "$tool" ]] || { echo "ERROR: required NDK tool missing: $tool" >&2; exit 1; }
done
for tool in curl sha256sum stat readelf file python3 make; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing host tool: $tool" >&2; exit 1; }
done

NDK_VERSION_FILE="$NDK/source.properties"
grep -q 'Pkg.Revision = 27.2.12479018' "$NDK_VERSION_FILE" || {
  echo "ERROR: expected NDK r27c (27.2.12479018)." >&2
  cat "$NDK_VERSION_FILE" >&2
  exit 1
}

NNUE_FILE="${PZ_NNUE_FILE:-$ROOT/nnue.bin}"
if [[ "$NNUE_FILE" != /* ]]; then NNUE_FILE="$ROOT/$NNUE_FILE"; fi
NNUE_URL="${PZ_NNUE_URL:-https://github.com/kevlu8/PZChessBot-Networks/releases/latest/download/nnue.bin}"
EXPECTED_NNUE_BYTES=86921760
if [[ ! -s "$NNUE_FILE" ]]; then
  echo "Fetching PZChessBot NNUE from: $NNUE_URL"
  curl --fail --location --retry 3 --retry-delay 2 --output "$NNUE_FILE" "$NNUE_URL"
fi
ACTUAL_NNUE_BYTES="$(stat -c '%s' "$NNUE_FILE")"
if [[ "$ACTUAL_NNUE_BYTES" != "$EXPECTED_NNUE_BYTES" ]]; then
  echo "ERROR: NNUE file size does not match this PZ source snapshot." >&2
  echo "Expected: $EXPECTED_NNUE_BYTES bytes (source layout from engine/nnue/network.hpp)." >&2
  echo "Actual:   $ACTUAL_NNUE_BYTES bytes." >&2
  echo "Refusing to embed a possibly incompatible network." >&2
  exit 1
fi

rm -rf artifacts
mkdir -p artifacts/arm64-neon artifacts/arm64-dotprod
sha256sum "$NNUE_FILE" | tee artifacts/NNUE-SHA256SUMS.txt

check_macros() {
  local march="$1" expected="$2" out="$3"
  printf '\n' | "$ANDROID_CXX" -march="$march" -dM -E -x c++ - > "$out"
  grep -q '__aarch64__' "$out"
  grep -q '__ARM_NEON' "$out"
  if [[ "$expected" == dotprod ]]; then
    grep -q '__ARM_FEATURE_DOTPROD' "$out"
  else
    if grep -q '__ARM_FEATURE_DOTPROD' "$out"; then
      echo "ERROR: baseline NEON flags unexpectedly enable Dotprod." >&2
      exit 1
    fi
  fi
}

verify_elf() {
  local binary="$1" mode="$2" disassembly
  file "$binary"
  readelf -h "$binary" | grep -q 'AArch64'
  if readelf -d "$binary" 2>/dev/null | grep -q 'libc++_shared.so'; then
    echo "ERROR: $binary depends on libc++_shared.so." >&2
    exit 1
  fi

  # Enforce 16 KiB PT_LOAD alignment for current Android devices.
  readelf -lW "$binary" > "$binary.program-headers.txt"
  python3 - "$binary.program-headers.txt" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
loads = [line for line in text.splitlines() if re.search(r"^\s*LOAD\s", line)]
if not loads:
    raise SystemExit("ERROR: no PT_LOAD segments found")
for line in loads:
    fields = line.split()
    align = int(fields[-1], 16)
    if align < 0x4000:
        raise SystemExit(f"ERROR: PT_LOAD alignment below 16 KiB: {line}")
print("PASS: all PT_LOAD segments are aligned to at least 16 KiB")
PY

  disassembly="${binary}.disassembly.txt"
  "$OBJDUMP" -d "$binary" > "$disassembly"
  if [[ "$mode" == neon ]]; then
    grep -Eiq '\b(sqrdmulh|smlal|smlal2)\b' "$disassembly" || {
      echo "ERROR: expected ARM NEON NNUE instructions not found." >&2; exit 1;
    }
    if grep -Eiq '\bsdot\b' "$disassembly"; then
      echo "ERROR: baseline NEON binary contains SDOT." >&2; exit 1
    fi
  else
    grep -Eiq '\bsdot\b' "$disassembly" || {
      echo "ERROR: Dotprod binary contains no SDOT instruction." >&2; exit 1;
    }
  fi
  sha256sum "$binary" | tee "${binary}.sha256"
}

build_variant() {
  local variant="$1" march="$2" target="$3" outdir="$4" mode="$5"
  local exe="pzchessbot-android-arm64-${variant}"
  echo "=== Building PZChessBot Android ARM64 ${variant} ==="
  check_macros "$march" "$mode" "/tmp/pz-${variant}-macros.txt"
  make clean CXX="$ANDROID_CXX" EXE="$exe" NUMA_NODES=1
  # Make's INCBIN path is relative to the repository root. If the caller
  # supplied an external NNUE path, stage it under the expected local name.
  if [[ "$NNUE_FILE" != "$ROOT/nnue.bin" ]]; then
    cp "$NNUE_FILE" "$ROOT/nnue.bin"
  fi
  make -j2 "$target" \
    CXX="$ANDROID_CXX" \
    EXE="$exe" \
    EVALFILE="nnue.bin" \
    NUMA_NODES=1
  test -s "$exe"
  cp "$exe" "$outdir/pzchessbot"
  verify_elf "$outdir/pzchessbot" "$mode"
  cat > "$outdir/ANDROID-BUILD-INFO.txt" <<EOF
Engine: PZChessBot (source snapshot supplied in the 2026-11-06 multi-engine compile bundle)
Target: Android ARM64 / Bionic, API 24
NDK: r27c (27.2.12479018)
Compiler: $ANDROID_CXX
Variant: $variant
Architecture flags: -march=$march -mtune=cortex-a76
NNUE: embedded into executable from nnue.bin
NNUE size: $ACTUAL_NNUE_BYTES bytes
NEON: enabled
Dotprod: $([[ "$mode" == dotprod ]] && echo enabled || echo disabled)
C++ runtime: static libc++ (no libc++_shared.so dependency)
ELF LOAD alignment: at least 16 KiB
EOF
}

check_macros armv8-a+simd neon /tmp/pz-neon-macros.txt
check_macros armv8.2-a+dotprod dotprod /tmp/pz-dotprod-macros.txt

bash scripts/test-simd-math-contract.sh

build_variant neon armv8-a+simd android-neon artifacts/arm64-neon neon
build_variant dotprod armv8.2-a+dotprod android-dotprod artifacts/arm64-dotprod dotprod

echo "PZChessBot Android ARM64 NEON + Dotprod build preparation completed."
