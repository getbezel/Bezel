#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$bezel_root/Scripts/test-stack.sh"
"$bezel_root/Scripts/test-airbridge.sh" "$@"
"$bezel_root/Scripts/test-system.sh"
"$bezel_root/Scripts/test-automation.sh"
"$bezel_root/Scripts/test-media.sh"
