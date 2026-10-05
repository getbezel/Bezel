#!/bin/bash
set -euo pipefail

bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-airbridge.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT

xcrun swiftc \
    -swift-version 6 \
    -target "$(uname -m)-apple-macos15.0" \
    -O \
    "$bezel_root/MyApp/Modules/AirBridge/AudioHardwareAccess.swift" \
    "$bezel_root/MyApp/Modules/AirBridge/AudioSpectrum.swift" \
    "$bezel_root/MyApp/Modules/AirBridge/AudioRouteEngine.swift" \
    "$bezel_root/Tests/AirBridge/RenderTests.swift" \
    -o "$bezel_test_build/airbridge-tests"

"$bezel_test_build/airbridge-tests" "$@"
