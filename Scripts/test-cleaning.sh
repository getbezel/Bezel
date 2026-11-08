#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/bezel-cleaning.XXXXXX")"
trap 'rm -rf "$bezel_test_dir"' EXIT
xcrun swiftc -swift-version 6 "$bezel_root/Untitled Project/Utilities/Cleaning/CleaningSession.swift" \
    "$bezel_root/Untitled Project/Utilities/Cleaning/CleaningInputShield.swift" \
    "$bezel_root/Tests/Cleaning/CleaningTests.swift" -o "$bezel_test_dir/cleaning"
"$bezel_test_dir/cleaning"
