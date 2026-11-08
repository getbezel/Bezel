#!/usr/bin/env python3
"""Prepare a version-checked ad-only Spotify copy; never install or launch it."""
import hashlib
import json
import pathlib
import plistlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESEARCH = ROOT / "Companions/Spotify/Research.noindex"
STAGING = ROOT / "Build/Spotify-Adblock.noindex"
ORIGINAL = pathlib.Path("/Applications/Spotify.app")
VERSION = "1.3.3.264"
COMMIT = "5cf0c31eb736af4c54624d517430790c5616bb82"

# The adapter retains upstream archive/snapshot handling and these ad patches.
# Upstream music-video entitlement, telemetry, UI and experiment patches are
# excluded. The product-state override sets only ads, not subscription type.
ADAPTER = r'''
macos_autoupdate_check() { :; }
run_patches() {
  local selected=() entry name
  for entry in "${aoEx[@]}" "${freeEx[@]}"; do
    name="${entry%%&*}"
    case "$name" in
      bGabo|bSlot|adsX2|adConfig|adsEmptyBlock|hptoFetch|sGate3|stateS3)
        selected+=("$entry") ;;
      esperantoProductState)
        entry="${entry/catalogue:\'premium\',type:\'premium\',name:\'Spotify\'/}"
        selected+=("$entry") ;;
    esac
  done
  perlVar "${selected[@]}"
  [[ "${bezelGateMatched:-0}" == 1 && "${bezelSlotsMatched:-0}" -ge 1 ]] || {
    echo "Required native ad patches did not match this binary; stop." >&2
    exit 65
  }
}
perlvar() {
  local output count
  output=$($perlVar 'BEGIN { $c = 0 } $c += s&'"${a[1]}"'&'"${a[2]}"'&'"${a[3]}"'; END { print $c }' "$p") || exit 65
  [[ "$output" =~ ^[0-9]+$ ]] || exit 65
  count="$output"
  printf 'BEZEL_PATCH %s %s\n' "${a[0]}" "$count"
  [[ "${a[0]}" == sGate3 ]] && bezelGateMatched="$count"
  [[ "${a[0]}" == bSlot ]] && bezelSlotsMatched="$count"
  return 0
}
'''

def run(*args):
    subprocess.run(args, check=True)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    if STAGING.exists():
        raise RuntimeError("A prepared copy already exists; inspect it before replacing anything.")
    version = plistlib.loads((ORIGINAL / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
    if version != VERSION or (RESEARCH / "commit.txt").read_text().strip() != COMMIT:
        raise RuntimeError("Spotify or upstream revision changed; review compatibility first.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(ORIGINAL))
    source = (RESEARCH / "spotx.sh").read_text()
    marker = "\ntrap cleanup_temp_dirs EXIT\n"
    if source.count(marker) != 1:
        raise RuntimeError("Unexpected upstream structure.")
    STAGING.mkdir(parents=True)
    # Copy-on-write cloning preserves the original and its full resources.
    run("/bin/cp", "-cRp", str(ORIGINAL), str(STAGING / "Spotify.app"))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(STAGING / "Spotify.app"))
    adapted = STAGING / "ad-only-spotx.sh"
    adapted.write_text(source.replace(marker, "\n" + ADAPTER + marker))
    import os
    env = dict(os.environ, SPOTX_BUILD_MODE="1")
    result = subprocess.run(["/bin/bash", str(adapted), "--noexp", "--noninteractive", "--nocolor",
        "-P", str(STAGING)], env=env, capture_output=True, text=True)
    (STAGING / "prepare.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Staged preparation failed. Original Spotify is untouched; inspect prepare.log.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(STAGING / "Spotify.app"))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(ORIGINAL))
    patches = []
    for line in result.stdout.splitlines():
        if line.startswith("BEZEL_PATCH "):
            _, name, count = line.split()
            patches.append({"name": name, "matches": int(count)})
    spa = "Contents/Resources/Apps/xpui.spa"
    binary = "Contents/MacOS/Spotify"
    report = {
        "status": "Prepared only; not installed or launched; live ad blocking unverified",
        "version": version, "upstream_commit": COMMIT, "patches": patches,
        "source_app": str(ORIGINAL), "prepared_app": str(STAGING / "Spotify.app"),
        "original_sha256": {p: sha(ORIGINAL / p) for p in [spa, binary]},
        "prepared_sha256": {p: sha(STAGING / "Spotify.app" / p) for p in [spa, binary]},
        "signature": "Prepared copy ad-hoc signed and strict deep verified; original signature still verified",
        "installation_effect": "Would replace Spotify locally; Automation access may need reconnection",
        "updates": "Not disabled; an update may replace these patches",
        "accounts_preferences_and_cache": "Untouched",
        "bezel_app": "Untouched",
        "live_validation": False,
        "ten_times_speed": False,
    }
    (STAGING / "Preparation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
