# DragWheel in Bezel

The user-provided DragWheel archive (source revision
`9fc8867d4880f153df53abd7a5d860cd8cba7448`) is integrated into Bezel's existing
host target under `Utilities/DragWheel`. Its standalone main, app delegate,
prebuilt application, installer, notification delegate and menu bar/login items
were not imported. Source adaptation is attributed in each imported component;
the supplied ZIP contains no standalone license file.

## Use

- Hold Shift during a file drag. Drop on an available format to convert; the
  center cancels. All selected files must share that output format.
- Find DragWheel under Capture & Collect in Bezel, or use its existing menu bar's
  Convert Files action. A normal file picker and format picker support keyboard
  and assistive-technology use without the radial gesture.
- Change the modifier or record a custom key in the page. Modifier triggers need
  no extra permission; custom keys may need macOS Input Monitoring.
- Results save beside the original. The original is never moved or modified;
  existing outputs are not replaced. Multi-page image exports create a folder.
- Jobs run serially, report completion/errors in Bezel, and can be cancelled.
  Recent results retain up to 50 entries, with Show in Finder for outputs.
- Optional Finder icon placement is off by default. Enabling it permits Bezel to
  ask for Finder Automation access; failures do not invalidate saved output.

## Helpers and limits

The page detects FFmpeg, ImageMagick, Pandoc and LibreOffice. Missing helpers are
labeled and their format choices disabled. Detection refreshes on each new drag
and via Refresh, so installing a helper does not require restarting Bezel. No
helper or separate application is installed by this integration.

PDF-to-document exports extract text rather than reconstructing layout.
Markdown falls back to plain text without Pandoc. Text parsing is capped at
32 MB and PDF conversions at 1,000 pages; oversized image/page renders are
rejected rather than silently reducing resolution. Native archive extraction
uses Bezel's bounded libarchive reader, including RAR support; unsafe paths,
links and special files are rejected. The original unar fallback is not used.

## Lifecycle and validation

BezelModel starts/stops the gesture watcher and drains its worker on shutdown.
Shelf suppresses its edge drawer while the DragWheel modifier or wheel owns the
drag. A fresh drag pasteboard change is required, and a drop must match the
files used to build the wheel. Polling slows when idle; no event tap or added
Accessibility request is used for the default gesture. Wheel fades respect
Reduce Motion. User defaults are namespaced under `dragWheel`.

The conversion adapter reuses Bezel's subprocess runner with literal arguments,
bounded output, a deadline and task cancellation. It uses private staging,
security-scoped file access, and safe extraction. LibreOffice receives an
isolated temporary profile per job. Cancelled work is cleaned before the worker
finishes. No source-controlled placeholder implementation or shell evaluation
is used for conversion.

Run `Scripts/test-dragwheel.sh` for real image, SVG, document, PDF, subtitle,
CSV/TSV, archive/folder and available FFmpeg conversions, collision/source
preservation, archive traversal rejection, cancellation, drag-session tracking,
wheel hit testing, queue behavior and subprocess directory/environment checks.
It creates only temporary fixtures and does not show the wheel, request privacy
grants, invoke Finder placement or perform a real Finder drag. Live gesture,
multi-display appearance, optional helper formats and Finder positioning still
need user acceptance on the signed build.

## Shelf handoff

Successful conversions keep the output beside the source and add both source and output references to Shelf. Shelf opens automatically after a successful conversion; an already open Shelf stays in place. Existing Shelf references are deduplicated. Failed or cancelled jobs do not add files. When Shelf reaches its 50-item limit, the saved output remains intact and DragWheel displays the capacity warning.
