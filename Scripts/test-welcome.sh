#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/bezel-welcome.XXXXXX")"
trap 'rm -rf "$bezel_test_dir"' EXIT
xcrun swiftc -swift-version 6 "$bezel_root/Untitled Project/Design/GreetingText.swift" \
    "$bezel_root/Tests/Welcome/GreetingTests.swift" -o "$bezel_test_dir/greetings"
"$bezel_test_dir/greetings"
