#!/bin/bash
# Runs the performance study's benchmarks (docs/feature-notes/perf.md) in a
# release build, one suite after another and never side by side, and
# collects every BENCH line into one file.
#
# Usage: scripts/bench.sh <results-file> [suite-filter ...]
#
#   results-file   where the BENCH lines go (replaced). The full test output
#                  goes beside it, as <results-file>.log.
#   suite-filter   run only these entries of the list below (a `swift test
#                  --filter` pattern each), e.g. ViewerBenchmark.
#
# Environment:
#   MINIVU_BENCH_DIR    the folder of real photos, only ever read
#                       (default ~/latent/TestAssets).
#   MINIVU_BENCH_QUICK  1: every benchmark small and twice, to see that it
#                       works; the numbers mean nothing.
#   MINIVU_BENCH_DEBUG  1: a debug build instead of release (with QUICK, to
#                       check the kit; never for numbers).
#   MINIVU_BENCH_OLDER  0: leave out the older print-only benchmarks, whose
#                       lines go to the log only.
#   SKIP_BUILD          1: use the test build already there.
#   BENCH_JOBS          the build's -j (all cores when unset).
#
# Every suite runs in a process of its own, so a memory figure is never
# inflated by the suite before it. The catalog is always the private one in
# memory (MINIVU_CATALOG=memory), and with it the thumbnail cache is one of
# the run's own in the temporary folder: nothing touches the user's.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "usage: scripts/bench.sh <results-file> [suite-filter ...]" >&2
  exit 2
fi
results=$1
shift
log="$results.log"

export MINIVU_BENCH=1
export MINIVU_BENCH_DIR="${MINIVU_BENCH_DIR:-$HOME/latent/TestAssets}"
export MINIVU_CATALOG=memory

jobs=()
[ -n "${BENCH_JOBS:-}" ] && jobs=(-j "$BENCH_JOBS")
if [ "${MINIVU_BENCH_DEBUG:-0}" = 1 ]; then
  build=(swift build --build-tests)
  test=(swift test --skip-build)
else
  build=(swift build -c release --build-tests -Xswiftc -enable-testing)
  test=(swift test -c release -Xswiftc -enable-testing --skip-build)
fi

# One entry per process, in this order. A suite of window tests runs with
# the other window suites' serialisation, so it is safe on its own too.
suites=(
  # MinivuCoreTests
  CatalogBenchmark
  ThumbnailBenchmark
  PhotoInfoBenchmark
  "SearchBenchmark/walkAndFindByName"
  "SearchBenchmark/findWithMetadataColdAndCached"
  "DuplicateBenchmark/exactAndSimilarOnTwoHundred"
  # MinivuRenderTests
  EditLatencyBenchmark
  SlideshowVideoBenchmark
  # MinivuTests
  FolderOpenBenchmark
  PixelSizeCacheBenchmark
  FilesBenchmark
  "ViewerBenchmark/openPerFormat"
  "ViewerBenchmark/nextAndPrevious"
  "ViewerBenchmark/zoomToActualSize"
  "ViewerBenchmark/memoryFlippingThroughTwenty"
  GridScrollBenchmark
  SaveBenchmark
  "BatchOutputBenchmark/batchConvert"
  "BatchOutputBenchmark/webGallery"
)
# The benchmarks from before the study: their own print format, log only.
older=(
  "SearchBenchmark/walkTwentyThousandFiles"
  "SearchBenchmark/metadataColdThenCached"
  "DuplicateBenchmark/indexTenAndTwentyThousandPrints"
  "DuplicateBenchmark/printsAndHashesColdThenCached"
  ExportBenchmark
  ColorCounterBenchmark
  DecodeBenchmark
  FitBenchmark
  RawBenchmark
  EditBenchmark
  EffectsBenchmark
  RetouchBenchmark
  RawMemoryBenchmark
  SlideshowBenchmark
  ThumbnailCommitBenchmark
)

if [ $# -gt 0 ]; then
  suites=("$@")
  older=()
elif [ "${MINIVU_BENCH_OLDER:-1}" = 0 ]; then
  older=()
fi

{
  echo "# minivu benchmarks $(date '+%Y-%m-%d %H:%M')"
  echo "# commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo ' (modified)')"
  echo "# $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string 2>/dev/null) $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
  echo "# build $([ "${MINIVU_BENCH_DEBUG:-0}" = 1 ] && echo debug || echo release)$([ "${MINIVU_BENCH_QUICK:-0}" != 0 ] && echo ', QUICK: not for numbers')"
  echo "# photos $MINIVU_BENCH_DIR"
} > "$results"
: > "$log"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo "Building…"
  "${build[@]}" ${jobs[@]+"${jobs[@]}"} >> "$log" 2>&1 || { echo "The build failed; see $log" >&2; exit 1; }
fi

failed=0
for suite in "${suites[@]}" ${older[@]+"${older[@]}"}; do
  echo "Running $suite…"
  echo "=== $suite" >> "$log"
  if ! "${test[@]}" --filter "$suite" >> "$log.part" 2>&1; then
    echo "  $suite failed; see $log" >&2
    echo "# FAILED $suite" >> "$results"
    failed=1
  fi
  grep '^BENCH ' "$log.part" >> "$results" || true
  cat "$log.part" >> "$log"
  rm -f "$log.part"
done

echo "$(grep -c '^BENCH ' "$results") metrics in $results"
exit $failed
