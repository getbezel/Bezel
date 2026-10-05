#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$bezel_root"
xcodebuild -project 'Untitled Project.xcodeproj' -scheme MyApp \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath .build -archivePath Build/Bezel.xcarchive \
    CODE_SIGN_IDENTITY=- archive
