#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_notch_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-notch.XXXXXX")"
trap 'rm -rf "$bezel_notch_build"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -mmacosx-version-min=15.0 -c \
  "$bezel_root/Untitled Project/Modules/AirBridge/PlayerAutomation.m" -o "$bezel_notch_build/player.o"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
  -import-objc-header "$bezel_root/Untitled Project/Modules/AirBridge/PlayerAutomation.h" \
  "$bezel_root/Untitled Project/Modules/AirBridge/NowPlayingMetadata.swift" \
  "$bezel_root/Untitled Project/Modules/AirBridge/PlaybackTimeline.swift" \
  "$bezel_root/Untitled Project/Modules/Stack/ClipboardImage.swift" \
  "$bezel_root/Untitled Project/Core/AccessibilityAccess.swift" \
  "$bezel_root/Untitled Project/Design/GlassAppearance.swift" \
  "$bezel_root/Untitled Project/Modules/Aperture/FocusStatusMonitor.swift" \
  "$bezel_root/Untitled Project/Modules/Aperture/MarqueeText.swift" \
  "$bezel_root/Untitled Project/Modules/Aperture/ApertureService.swift" \
  "$bezel_root/Untitled Project/Modules/Aperture/ApertureView.swift" \
  "$bezel_root/Tests/Interface/NotchPlayerTests.swift" "$bezel_notch_build/player.o" \
  -framework ScriptingBridge -framework CoreServices -framework AppKit \
  -o "$bezel_notch_build/notch-tests"
"$bezel_notch_build/notch-tests"
