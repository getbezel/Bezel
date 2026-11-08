#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-dragwheel.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT
python3 - "$bezel_test_build" <<'PY'
import tarfile, sys, pathlib
p=pathlib.Path(sys.argv[1])/'unsafe.tar'
with tarfile.open(p,'w') as t:
    t.addfile(tarfile.TarInfo('../outside.txt'))
PY
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
    "$bezel_root/Untitled Project/Core/CommandRunner.swift" \
    "$bezel_root/Untitled Project/Utilities/Scope/SafeArchive.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelFormats.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelTools.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelConverter.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelTrigger.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelWatcher.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelRadialMenu.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelPlacement.swift" \
    "$bezel_root/Untitled Project/Utilities/DragWheel/DragWheelService.swift" \
    "$bezel_root/Tests/DragWheel/ConversionTests.swift" \
    -o "$bezel_test_build/dragwheel-tests"
"$bezel_test_build/dragwheel-tests" "$bezel_test_build/unsafe.tar"
