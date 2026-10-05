#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_media_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-media.XXXXXX")"
trap 'rm -rf "$bezel_media_build"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -mmacosx-version-min=15.0 -c \
    "$bezel_root/MyApp/Modules/AirBridge/PlayerAutomation.m" -o "$bezel_media_build/player.o"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
    -import-objc-header "$bezel_root/MyApp/Modules/AirBridge/PlayerAutomation.h" \
    "$bezel_root/MyApp/Modules/AirBridge/NowPlayingMetadata.swift" \
    "$bezel_root/MyApp/Modules/Stack/ClipboardImage.swift" \
    "$bezel_root/Tests/Media/ArtworkFixture.swift" \
    "$bezel_root/Tests/Media/MetadataTests.swift" "$bezel_media_build/player.o" \
    -framework ScriptingBridge -framework CoreServices -framework AppKit \
    -o "$bezel_media_build/media-tests"
"$bezel_media_build/media-tests"
