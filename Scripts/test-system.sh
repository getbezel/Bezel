#!/bin/bash
set -euo pipefail
bezel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bezel_test_build="$(mktemp -d "${TMPDIR:-/tmp}/bezel-system.XXXXXX")"
trap 'rm -rf "$bezel_test_build"' EXIT
python3 - "$bezel_test_build" "$bezel_root/Tests/System/Fixtures/rar5-stored.rar.uu" <<'PY'
from pathlib import Path
import binascii, io, sys, tarfile
root=Path(sys.argv[1])
encoded=Path(sys.argv[2]).read_bytes().splitlines()
(root/'normal.rar').write_bytes(b''.join(binascii.a2b_uu(line) for line in encoded[1:-1]))
source=root/'sevenzip-source'; source.mkdir()
(source/'hello.txt').write_text('Bezel 7z verification\n')
with tarfile.open(root/'normal.tar.gz','w:gz') as archive:
 for name,content in [('folder/hello world.txt',b'Bezel archive verification\n'),('folder/.hidden',b'Included in storage counts')]:
  entry=tarfile.TarInfo(name); entry.size=len(content); archive.addfile(entry,io.BytesIO(content))
for kind in ['traversal','absolute','symlink','hardlink','duplicate','device','oversized']:
 with tarfile.open(root/(kind+'.tar'),'w') as archive:
  entry=tarfile.TarInfo('safe.txt')
  if kind=='traversal':entry.name='../outside.txt'
  elif kind=='absolute':entry.name='/tmp/bezel-forbidden.txt'
  elif kind=='symlink':entry.type=tarfile.SYMTYPE; entry.linkname='/tmp'
  elif kind=='hardlink':entry.type=tarfile.LNKTYPE; entry.linkname='other'
  elif kind=='device':entry.type=tarfile.CHRTYPE
  elif kind=='oversized':entry.size=33*1024**3
  if kind=='oversized':
   # A header alone is sufficient: size is rejected before data reads.
   archive.fileobj.write(entry.tobuf()); continue
  archive.addfile(entry)
  if kind=='duplicate': archive.addfile(tarfile.TarInfo('safe.txt'))
PY
/usr/bin/tar --format=7zip -cf "$bezel_test_build/normal.7z" -C "$bezel_test_build/sevenzip-source" hello.txt
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" -O \
    "$bezel_root/MyApp/Core/ScopeRequest.swift" \
    "$bezel_root/MyApp/Core/SessionCountdown.swift" \
    "$bezel_root/MyApp/Utilities/Scope/SafeArchive.swift" \
    "$bezel_root/MyApp/Utilities/Scope/ScopeService.swift" \
    "$bezel_root/MyApp/Utilities/Scope/ArchiveInspectionView.swift" \
    "$bezel_root/MyApp/Utilities/Pulse/PulseService.swift" \
    "$bezel_root/Tests/System/SystemTests.swift" \
    -o "$bezel_test_build/system-tests"
"$bezel_test_build/system-tests" "$bezel_test_build"
