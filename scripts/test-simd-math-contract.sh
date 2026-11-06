#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CXX="${HOST_CXX:-g++}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CXX" -std=c++20 -O2 -Wall -Wextra -Werror \
  "$ROOT/tests/simd-math-contract.cpp" -o "$TMP/simd-math-contract"
"$TMP/simd-math-contract"
