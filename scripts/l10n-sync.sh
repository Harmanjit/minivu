#!/bin/bash
# Brings every target's Localizable.xcstrings up to date with the source.
#
# Usage: scripts/l10n-sync.sh
#
# It builds (debug, Swift Build), then hands each target's catalog the
# .stringsdata files the compiler wrote beside its objects: one per source
# file, listing every string literal that became a LocalizedStringResource
# or String.LocalizationValue (`localized("…")`, String(localized:), Text in
# SwiftUI), with its `comment:` and its interpolations as format specifiers
# (%lld, %@). `xcstringstool sync` then
#   - adds new keys, with their comments, untranslated;
#   - keeps every existing translation and its state;
#   - marks keys no source uses any more "stale" (they still ship; delete
#     them from the catalog once nobody needs their translations).
# Run it after adding or changing user-facing strings, before translating,
# and commit the catalogs with the code. It builds, so on a shared machine
# run it through the build throttle.
#
# Mechanism and conventions: docs/feature-notes/l10n.md.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! swift build --build-system swiftbuild -j 4 >/dev/null 2>&1; then
  swift build --build-system swiftbuild -j 4
  exit 1
fi

ARCH=$(uname -m)
DEBUG=.build/out/Intermediates.noindex/minivu.build/Debug
ROOT=$(pwd -P)

# Target, its build folder, and the name of its file list. The executable
# target is built as the product, "minivu".
sync_target() {
  local target=$1 folder=$2 module=$3
  local objects="$DEBUG/$folder/Objects-normal/$ARCH"
  local list="$objects/$module.SwiftFileList"
  [ -f "$list" ] || { echo "No $list: has the build layout changed?" >&2; exit 1; }
  # Only the files this build compiled, so a deleted file's strings go
  # stale; and only the target's own sources, not generated ones (the
  # catalog's own symbols would keep every key alive).
  local args=()
  while IFS= read -r source; do
    case "$source" in "$ROOT/Sources/$target/"*) ;; *) continue ;; esac
    local data="$objects/$(basename "$source" .swift).stringsdata"
    if [ -f "$data" ]; then args+=(--stringsdata "$data"); fi
  done < "$list"
  [ ${#args[@]} -gt 0 ] || { echo "No .stringsdata for $target" >&2; exit 1; }
  # sync matches a catalog to its table by file name: it must stay
  # Localizable.xcstrings.
  xcrun xcstringstool sync "Sources/$target/Localizable.xcstrings" "${args[@]}"
  echo "$target: $(xcrun xcstringstool print "Sources/$target/Localizable.xcstrings" 2>/dev/null | grep -c . || true) keys"
}

sync_target MinivuCore MinivuCore-t.build MinivuCore
sync_target MinivuRender MinivuRender-t.build MinivuRender
sync_target Minivu minivu-p.build minivu
