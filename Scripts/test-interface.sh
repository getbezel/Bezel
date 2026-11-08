#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-interface.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
  "$bezel_root/Untitled Project/Modules/Aperture/FocusStatusMonitor.swift" \
  "$bezel_root/Untitled Project/Utilities/Shelf/ShelfImageStore.swift" \
  "$bezel_root/Untitled Project/Core/CallbackDeadline.swift" \
  "$bezel_root/Untitled Project/Core/AccessibilityAccess.swift" \
  "$bezel_root/Untitled Project/Utilities/Monolith/FocusBackdrop.swift" \
  "$bezel_root/Untitled Project/Modules/Stack/ClipboardCommandExecutor.swift" \
  "$bezel_root/Tests/Interface/InterfaceTests.swift" \
  -o "$bezel_test_build/interface-tests"
"$bezel_test_build/interface-tests"
