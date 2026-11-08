#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-automation.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT
xcrun clang -Wall -Wextra "$bezel_root/Tests/Automation/CommandFixture.c" -o "$bezel_test_build/command-fixture"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
    "$bezel_root/Untitled Project/Core/CommandRunner.swift" \
    "$bezel_root/Untitled Project/Utilities/Monolith/FocusAutomation.swift" \
    "$bezel_root/Untitled Project/Utilities/Tether/NativeChargeControl.swift" \
    "$bezel_root/Untitled Project/Utilities/MenuBar/MenuBarInventory.swift" \
    "$bezel_root/Tests/Automation/AutomationTests.swift" \
    -o "$bezel_test_build/automation-tests"
"$bezel_test_build/automation-tests" "$bezel_test_build/command-fixture"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation \
    "$bezel_root/Untitled Project/Utilities/Tether/ChargeAgent/main.m" -o "$bezel_test_build/charge-agent"
"$bezel_test_build/charge-agent" status
if "$bezel_test_build/charge-agent" limit79 > "$bezel_test_build/rejection.json"; then
    printf 'An unknown battery action was incorrectly accepted.\n' >&2; exit 1
fi
python3 - "$bezel_test_build/rejection.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result['error']=='Unknown charge-control action.'
print('Native charge agent rejects unsupported actions before loading the hardware interface.')
PY
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation \
    -I "$bezel_root/Untitled Project/Utilities/MenuBar" \
    "$bezel_root/Untitled Project/Utilities/MenuBar/MenuVisibility.m" \
    "$bezel_root/Tests/Automation/NativeProbes.m" -o "$bezel_test_build/native-probes"
"$bezel_test_build/native-probes"
