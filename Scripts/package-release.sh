#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_mode=release
case "${1:-}" in
    --development) bezel_mode=development ;;
    --early-access) bezel_mode=early_access ;;
    "") ;;
    --help)
        echo 'Usage: package-release.sh [--development | --early-access]'
        echo 'Release mode requires BEZEL_SIGNING_IDENTITY, BEZEL_DEVELOPMENT_TEAM and BEZEL_NOTARY_PROFILE, and submits the signed image to Apple.'
        echo 'Development mode creates an unsigned, unnotarized local image without network access.'
        exit 0 ;;
    *) echo 'Usage: package-release.sh [--development | --early-access]' >&2; exit 64 ;;
esac
if (( $# > 1 )); then
    echo 'Only one optional argument is supported.' >&2
    exit 64
fi
bezel_archive="${BEZEL_ARCHIVE_PATH:-$bezel_root/Build/Bezel-Signed.xcarchive}"
bezel_app="$bezel_archive/Products/Applications/Bezel.app"
bezel_signing_identity="${BEZEL_SIGNING_IDENTITY:-}"
bezel_notary_profile="${BEZEL_NOTARY_PROFILE:-}"
bezel_development_team="${BEZEL_DEVELOPMENT_TEAM:-}"
if [[ "$bezel_mode" == release ]]; then
    if [[ "$bezel_signing_identity" != "Developer ID Application:"* || -z "$bezel_notary_profile" || ! "$bezel_development_team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo 'Release packaging requires a Developer ID Application identity, BEZEL_DEVELOPMENT_TEAM, and a stored notarytool Keychain profile.' >&2
        echo 'Use --development for an explicitly unnotarized local package.' >&2
        exit 64
    fi
fi
if [[ ! -d "$bezel_app" ]]; then
    echo 'Build the Release archive with Scripts/build-release.sh first.' >&2
    exit 66
fi
/usr/bin/codesign --verify --all-architectures --deep --strict "$bezel_app"
bezel_signatures=("$bezel_app" "$bezel_app/Contents/PlugIns/BezelFinder.appex" "$bezel_app/Contents/Helpers/BezelChargeAgent")
for bezel_signed_item in "${bezel_signatures[@]}"; do
    for bezel_architecture in arm64 x86_64; do
        bezel_signature=$(/usr/bin/codesign --display --arch "$bezel_architecture" --verbose=4 "$bezel_signed_item" 2>&1)
        if [[ "$bezel_mode" == release ]]; then
            if [[ "$bezel_signature" != *"Authority=Developer ID Application:"* || "$bezel_signature" != *"runtime)"* || "$bezel_signature" != *"Timestamp="* || "$bezel_signature" != *"TeamIdentifier=$bezel_development_team"* ]]; then
                echo "Missing matching Developer ID team, hardened runtime, or secure timestamp in $bezel_signed_item ($bezel_architecture)." >&2
                exit 65
            fi
        fi
    done
done
bezel_stage=$(mktemp -d "$bezel_root/Build/.package.XXXXXX")
trap 'rm -rf "$bezel_stage"' EXIT
mkdir "$bezel_stage/Contents"
/usr/bin/ditto "$bezel_app" "$bezel_stage/Contents/Bezel.app"
/bin/ln -s /Applications "$bezel_stage/Contents/Applications"
/usr/bin/codesign --verify --all-architectures --deep --strict "$bezel_stage/Contents/Bezel.app"
bezel_volume=Bezel
bezel_output="$bezel_root/Build/Bezel.dmg"
if [[ "$bezel_mode" == development ]]; then
    bezel_volume='Bezel Development'
    bezel_output="$bezel_root/Build/Bezel-Development.dmg"
    cat > "$bezel_stage/Contents/Read Me.txt" <<'NOTICE'
Bezel local development build

Drag Bezel.app to Applications to install. This package is not Developer ID
signed or notarized and has not completed the live hardware acceptance checks.
Closing the dashboard leaves Bezel running in the menu bar. Use Quit Bezel
in its menu to stop background services. Battery controls are opt-in.
NOTICE
fi
if [[ "$bezel_mode" == early_access ]]; then
    bezel_volume='Bezel Early Access'
    bezel_output="$bezel_root/Build/Bezel-Early-Access-Unnotarized.dmg"
fi
for bezel_document in EarlyAccessSetup EarlyAccessTerms ThirdPartyNotices; do
    /bin/cp "$bezel_root/Untitled Project/Legal/$bezel_document.txt" "$bezel_stage/Contents/$bezel_document.txt"
done
bezel_candidate="$bezel_stage/Bezel.dmg"
if /usr/sbin/diskutil image create from --help > /dev/null 2>&1; then
    /usr/sbin/diskutil image create from --volumeName "$bezel_volume" --format UDZO "$bezel_stage/Contents" "$bezel_candidate"
else
    /usr/bin/hdiutil create -volname "$bezel_volume" -srcfolder "$bezel_stage/Contents" -format UDZO "$bezel_candidate"
fi
/usr/bin/hdiutil verify "$bezel_candidate"
if [[ "$bezel_mode" == release ]]; then
    /usr/bin/codesign --sign "$bezel_signing_identity" --timestamp --identifier com.bezel.utility.diskimage "$bezel_candidate"
    /usr/bin/codesign --verify --strict "$bezel_candidate"
    if ! /usr/bin/xcrun notarytool submit "$bezel_candidate" --keychain-profile "$bezel_notary_profile" --wait --timeout 30m --output-format json > "$bezel_stage/Notarization.json"; then
        /bin/cp "$bezel_stage/Notarization.json" "$bezel_root/Build/Notarization.json"
        echo 'Notarization submission or wait failed. The response is retained in Build/Notarization.json; no release image was replaced.' >&2
        exit 1
    fi
    /bin/cp "$bezel_stage/Notarization.json" "$bezel_root/Build/Notarization.json"
    bezel_notary_status=$(/usr/bin/plutil -extract status raw -o - "$bezel_stage/Notarization.json")
    if [[ "$bezel_notary_status" != Accepted ]]; then
        echo "Notarization was not accepted ($bezel_notary_status). See Build/Notarization.json for the submission identifier." >&2
        exit 65
    fi
    /usr/bin/xcrun stapler staple "$bezel_candidate"
    /usr/bin/xcrun stapler validate "$bezel_candidate"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$bezel_candidate"
fi
/bin/mv -f "$bezel_candidate" "$bezel_output"
(
    cd "$bezel_root/Build"
    /usr/bin/shasum -a 256 "${bezel_output##*/}" > "${bezel_output##*/}.sha256"
)
echo "Created $bezel_output"
