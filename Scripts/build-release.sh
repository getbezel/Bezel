#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_signing_identity="${BEZEL_SIGNING_IDENTITY:-Apple Development}"
bezel_development_team="${BEZEL_DEVELOPMENT_TEAM:-}"
# Package resource bundles also need the host's team passed to xcodebuild.
if [[ -z "$bezel_development_team" ]]; then
    bezel_development_team="$(python3 - "$bezel_root/Configuration/Local.xcconfig" <<'PYTEAM'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
teams = set(re.findall(r'^\s*BEZEL_DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$', path.read_text() if path.exists() else '', re.M))
print(next(iter(teams)) if len(teams) == 1 else '')
PYTEAM
)"
fi
bezel_archive="${BEZEL_ARCHIVE_PATH:-$bezel_root/Build/Bezel-Signed.xcarchive}"
bezel_derived_data="${BEZEL_DERIVED_DATA_PATH:-$bezel_root/.build}"
# Replacing a running ad-hoc executable invalidates its current identity.
# Build elsewhere instead of silently breaking permissions in the loaded app.
python3 - "$bezel_archive" <<'PYGUARD'
import pathlib, subprocess, sys
archive = pathlib.Path(sys.argv[1]).resolve()
executable = str(archive / 'Products/Applications/Bezel.app/Contents/MacOS/Bezel')
processes = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
for line in processes.splitlines():
    pieces = line.strip().split(None, 1)
    if len(pieces) == 2 and pieces[1] == executable:
        print('Bezel is running from this archive. Quit it before replacing the archive, or set BEZEL_ARCHIVE_PATH to a different output path.', file=sys.stderr)
        sys.exit(73)
PYGUARD
bezel_signing_arguments=("CODE_SIGN_IDENTITY=$bezel_signing_identity")
if [[ "$bezel_signing_identity" == "Apple Development" || "$bezel_signing_identity" == "Apple Development:"* ]]; then
    bezel_signing_arguments+=("CODE_SIGN_STYLE=Automatic" "-allowProvisioningUpdates")
    if [[ -n "$bezel_development_team" ]]; then
        if [[ ! "$bezel_development_team" =~ ^[A-Z0-9]{10}$ ]]; then
            echo 'BEZEL_DEVELOPMENT_TEAM must be a ten-character team identifier.' >&2
            exit 64
        fi
        bezel_signing_arguments+=("DEVELOPMENT_TEAM=$bezel_development_team")
    fi
elif [[ "$bezel_signing_identity" == "Developer ID Application:"* ]]; then
    if [[ ! "$bezel_development_team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo 'Set BEZEL_DEVELOPMENT_TEAM to the ten-character team identifier for the signing certificate.' >&2
        exit 64
    fi
    bezel_signing_arguments+=("CODE_SIGN_STYLE=Manual" "DEVELOPMENT_TEAM=$bezel_development_team" "OTHER_CODE_SIGN_FLAGS=--timestamp")
elif [[ "$bezel_signing_identity" != "-" ]]; then
    echo 'Use Apple Development, an exact Apple Development/Developer ID Application identity, or - for explicitly ad-hoc development.' >&2
    exit 64
fi
cd "$bezel_root"
xcodebuild -project 'Untitled Project.xcodeproj' -scheme 'Untitled Project' \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$bezel_derived_data" -archivePath "$bezel_archive" \
    "${bezel_signing_arguments[@]}" archive
