#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/bezel-dashboard.XXXXXX")"
trap 'rm -rf "$bezel_test_dir"' EXIT
xcrun swiftc -swift-version 6 "$bezel_root/Untitled Project/Core/DashboardLayout.swift" \
    "$bezel_root/Tests/Dashboard/DashboardTests.swift" -o "$bezel_test_dir/dashboard"
"$bezel_test_dir/dashboard"
