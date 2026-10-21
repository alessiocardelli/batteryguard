#!/bin/sh
# Test dei casi limite della configurazione. swiftc diretto per lo stesso motivo di build.sh.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/tests"
mkdir -p "$OUT"

xcrun swiftc -target arm64-apple-macos13 -module-name LimitConfigTests \
  "$ROOT/Sources/SMCKit/LimitConfig.swift" "$ROOT/Tests/LimitConfigTests/main.swift" \
  -o "$OUT/limit-config-tests"
"$OUT/limit-config-tests"
