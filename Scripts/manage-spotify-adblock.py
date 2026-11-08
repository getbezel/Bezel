#!/usr/bin/env python3
"""Install or restore the prepared Spotify copy after explicit owner approval."""
import argparse
import json
import os
import pathlib
import subprocess
import hashlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
STAGING = ROOT / "Build/Spotify-Adblock.noindex"
RECOVERY = ROOT / "Build/Spotify-Recovery.noindex"
CURRENT = pathlib.Path("/Applications/Spotify.app")
STOCK = RECOVERY / "StockSpotify.bundle"
RETIRED = RECOVERY / "PatchedSpotify.bundle"
TEMP = pathlib.Path("/Applications/.BezelSpotify-Staging.noindex")
STATE = RECOVERY / "Installation.json"

QUIT = '''
import AppKit
import Foundation
let expected = URL(fileURLWithPath: "/Applications/Spotify.app").standardizedFileURL
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == expected }
for app in apps {
    guard app.terminate() else { fputs("Spotify refused a normal quit.\\n", stderr); exit(1) }
}
let deadline = Date().addingTimeInterval(12)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy({ $0.isTerminated }) else { fputs("Spotify did not quit.\\n", stderr); exit(1) }
'''

def verify(app, expected):
    for relative, digest in expected.items():
        actual = hashlib.sha256((app / relative).read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError(f"{app} changed since preparation; refusing replacement.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)

def quit_spotify():
    subprocess.run(["/usr/bin/xcrun", "swift", "-"], input=QUIT, text=True, check=True, timeout=45)

def launch():
    subprocess.run(["/usr/bin/open", str(CURRENT)], check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "install", "restore"])
    action = parser.parse_args().action
    preparation = json.loads((STAGING / "Preparation.json").read_text())
    if action == "status":
        print(json.dumps({"preparation": preparation, "installed": STATE.exists(),
            "recovery_available": STOCK.exists()}, indent=2))
        return
    if action == "install":
        if STOCK.exists() or TEMP.exists() or STATE.exists():
            raise RuntimeError("Recovery or installation state already exists; inspect it first.")
        verify(CURRENT, preparation["original_sha256"])
        prepared = pathlib.Path(preparation["prepared_app"])
        verify(prepared, preparation["prepared_sha256"])
        RECOVERY.mkdir(parents=True, exist_ok=True)
        TEMP.mkdir()
        subprocess.run(["/bin/cp", "-cRp", str(prepared), str(TEMP / "Spotify.app")], check=True)
        verify(TEMP / "Spotify.app", preparation["prepared_sha256"])
        quit_spotify()
        # Quit may complete an update; check again before replacing anything.
        verify(CURRENT, preparation["original_sha256"])
        os.rename(CURRENT, STOCK)
        try:
            os.rename(TEMP / "Spotify.app", CURRENT)
            verify(CURRENT, preparation["prepared_sha256"])
            state = {"status": "Installed; actual ad-blocking acceptance pending",
                "preparation": preparation, "stock_backup": str(STOCK),
                "restore_command": "python3 Scripts/manage-spotify-adblock.py restore"}
            STATE.write_text(json.dumps(state, indent=2) + "\n")
            launch()
        except BaseException:
            if CURRENT.exists():
                if RETIRED.exists():
                    raise RuntimeError("Rollback destination occupied; original remains in recovery.")
                os.rename(CURRENT, RETIRED)
            os.rename(STOCK, CURRENT)
            if STATE.exists(): STATE.unlink()
            launch()
            raise
        TEMP.rmdir()
        print("Prepared Spotify installed and opened. Original bundle retained for exact restoration.")
    else:
        if not STATE.exists() or not STOCK.exists() or RETIRED.exists():
            raise RuntimeError("Expected original backup is unavailable or recovery destination occupied.")
        verify(CURRENT, preparation["prepared_sha256"])
        verify(STOCK, preparation["original_sha256"])
        quit_spotify()
        verify(CURRENT, preparation["prepared_sha256"])
        os.rename(CURRENT, RETIRED)
        try:
            os.rename(STOCK, CURRENT)
            verify(CURRENT, preparation["original_sha256"])
        except BaseException:
            if CURRENT.exists(): os.rename(CURRENT, STOCK)
            os.rename(RETIRED, CURRENT)
            launch()
            raise
        STATE.rename(RECOVERY / "RestoredInstallation.json")
        launch()
        print("Exact original Spotify bundle and signature restored and opened.")

if __name__ == "__main__":
    main()
