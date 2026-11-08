#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$bezel_root/Tests/Media/YouTubeMusicTests.cjs"
