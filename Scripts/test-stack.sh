#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-stack.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT
xcrun swiftc -swift-version 6 -O "$bezel_root/Untitled Project/Modules/Stack/ClipboardStore.swift" "$bezel_root/Untitled Project/Modules/Stack/ClipboardImage.swift" "$bezel_root/Tests/Stack/StoreTests.swift" -o "$bezel_test_build/stack-tests"
"$bezel_test_build/stack-tests"
