#!/bin/sh
# Test dei casi limite di configurazione, battito del servizio, schemi di ricarica, ciclo del servizio sul finto SMC,
# segnalazione e aggiornamenti. swiftc diretto per lo stesso motivo di build.sh.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/tests"
mkdir -p "$OUT"

xcrun swiftc -target arm64-apple-macos13 -module-name LimitConfigTests \
  "$ROOT/Sources/SMCKit/LimitConfig.swift" "$ROOT/Tests/LimitConfigTests/main.swift" \
  -o "$OUT/limit-config-tests"
"$OUT/limit-config-tests"

xcrun swiftc -target arm64-apple-macos13 -module-name ServiceStatusTests \
  "$ROOT/Sources/SMCKit/ServiceStatus.swift" "$ROOT/Tests/ServiceStatusTests/main.swift" \
  -o "$OUT/service-status-tests"
"$OUT/service-status-tests"

xcrun swiftc -target arm64-apple-macos13 -module-name ChargingSchemeTests \
  "$ROOT/Sources/SMCKit/ChargingScheme.swift" "$ROOT/Tests/ChargingSchemeTests/main.swift" \
  -o "$OUT/charging-scheme-tests"
"$OUT/charging-scheme-tests"

# Ciclo vero del servizio su ogni profilo del finto SMC (Tests/fixtures/smc-profiles)
xcrun swiftc -target arm64-apple-macos13 -module-name ChargeLoopTests -framework IOKit \
  "$ROOT"/Sources/SMCKit/*.swift "$ROOT/Tests/ChargeLoopTests/main.swift" \
  -o "$OUT/charge-loop-tests"
"$OUT/charge-loop-tests" "$ROOT/Tests/fixtures/smc-profiles"

xcrun swiftc -target arm64-apple-macos13 -module-name ReportTests \
  "$ROOT/Sources/BatteryGuard/Report.swift" "$ROOT/Tests/ReportTests/main.swift" \
  -o "$OUT/report-tests"
"$OUT/report-tests"

xcrun swiftc -target arm64-apple-macos13 -module-name UpdateTests \
  "$ROOT/Sources/BatteryGuard/UpdateCore.swift" "$ROOT/Tests/UpdateTests/main.swift" \
  -o "$OUT/update-tests"
"$OUT/update-tests" "$ROOT/Tests/UpdateTests/github-release-latest.json"
