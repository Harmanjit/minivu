# Feature notes: cooperative-pool starvation (branch feature/coop-starvation)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section says where it should.

There is nothing new for the user to do: no menu, shortcut, setting or
default changes. The work removes a deadlock that hung the whole
MinivuCoreTests run, makes sure the app cannot reach the same state, and
adds a debug-build check and regression tests that catch it coming back.

## The symptom

On macOS 27.2 (M4, 10 cores) the full MinivuCoreTests run hung for ever at
0% CPU, every time. `ExportAVIFTests` alone passed (6 tests, 0.2 s),
`DuplicateFinderTests` alone passed (21 tests, 0.3 s), and the two together
(`--filter "ExportAVIFTests|DuplicateFinderTests"`) hung every time.

A `sample` of the hung process (taken again on this branch before the fix,
same picture): 10 threads of the default-QoS cooperative pool (7 labelled
`com.apple.root.default-qos.cooperative`, 3 relabelled
`com.apple.root.default-qos` by `dispatch_apply`), every one parked in
`__ulock_wait`:

- the AVIF tests in `ImageEncoder.encode` → `CGImageDestinationFinalize` →
  `IIO_Writer_HEIF` → CMPhoto → `VTTileCompressionSessionCompleteTiles` →
  `AV1EncoderSW` → `_dispatch_group_wait_slow`;
- the duplicate tests in `FeaturePrint.make(from:)` → `VNImageRequestHandler`
  → `-[VNControlledCapacityTasksQueue dispatchGroupWait:error:]`, including
  through `DuplicateFinder.featurePrints`' `concurrentPerform`.

No thread was doing the work they waited for, and GCD had started no
worker thread for it.

## What was proved (goal 1)

All measured on this Mac with temporary tests in MinivuCoreTests (removed
before committing; the shapes are described here so they can be rebuilt).
"Blocker" means a `Task.detached` that signals it started and then waits on
a semaphore; a watchdog on a plain `Thread` releases the blockers after a
timeout, so a starved probe recovers instead of hanging.

**1. The working hypothesis was wrong as stated.** It said the frameworks
run their inner work on the Swift cooperative pool. Blocking all 10
cooperative threads and then calling one AVIF encode, HEIC encode or
feature print from a GCD thread: every call finished (0.005 to 0.26 s),
cold (first call in the process) and warm. So the frameworks' inner work
is not scheduled on the pool itself.

**2. It matters where the caller is.** The same call made *from a
cooperative thread*, with the other 9 cooperative threads blocked, never
finished (15 s timeout, both AVIF and feature print). With 8 blocked (one
cooperative thread left idle) it finished. Ten callers on cooperative
threads and no blockers: a permanent deadlock, the hung suite in miniature.
Thirty callers on GCD threads at the default QoS, with the 10 cooperative
threads blocked: none finished, and a `sample` showed *no* thread running
the GCD work at all.

**3. The mechanism, without any framework.** With all 10 default-QoS
cooperative threads blocked, a trivial `DispatchQueue.global(qos: .default)`
item (signal a semaphore) did not run within 5 s. With 9 blocked it ran at
once. With 10 or 40 *GCD* threads blocked at the default QoS instead, it
ran at once. With the cooperative threads blocked, a `.utility` item was
starved too, while a `.userInitiated` item ran.

So: **a cooperative thread blocked in a wait keeps its place in GCD's
thread budget for its QoS (one thread per core). While every cooperative
thread of a QoS is blocked, GCD starts no thread for work at that QoS or
below.** A blocked GCD worker gives its place back (GCD grows threads for
blocked work, as `BlockingWork` always assumed); a blocked cooperative
thread does not. Vision (`VNControlledCapacityTasksQueue`) and ImageIO's
HEIF and AVIF encoders (CMPhoto, VideoToolbox, `AV1EncoderSW`) hand their
work to GCD at the caller's QoS and wait for it in a dispatch group. Called
from enough cooperative threads at once, that work never starts.

Why probe 1 passed: the work was dispatched from inside `BlockingWork`, a
user-initiated GCD thread, so the framework's inner work carried the
user-initiated QoS, which the blocked default-QoS pool doesn't starve. Why
the two suites hang only together: Swift Testing runs tests in parallel on
the pool at the default QoS, so it took both suites' blocking tests at once
to fill all ten threads with waits.

**4. It reaches user-initiated work too.** With the *user-initiated*
cooperative threads held instead (the QoS the app's main-actor tasks run
at), 20 AVIF encodes and feature prints run through `BlockingWork`
(user-initiated GCD) finished none of 20 by the 10 s deadline. So
`BlockingWork` is not a shield on its own: the rule is that these calls
must never block a cooperative thread at all, at any QoS.

## The fix

### Production (goals 2 and 3)

- **`BlockingWork` documents the deadlock** next to the existing reason
  (slowness), so the rule is where people look for it.
- **`BlockingWork.isOnCooperativeThread`**: true on a thread of the
  cooperative pool, read from the current dispatch queue's label
  (`com.apple.root.<qos>.cooperative`). Cheap (a pointer and a string
  compare).
- **`BlockingWork.expectOffCooperativePool(_:)`**: called at the top of each
  synchronous helper that waits on a framework's queue. Debug builds count
  a call made on a cooperative thread and print once per helper on
  standard error: `minivu: FeaturePrint.make(from:) blocked a cooperative
  thread; call it through BlockingWork.run`. Release builds compile it to
  nothing (lean: no work in shipping builds). A task-local
  `BlockingWork.cooperativeCallLog` lets a test collect the calls its own
  task made, without counting other tests running beside it. Placed in:
  `FeaturePrint.make(from:)`, `SubjectDetector.mask(in:)` (Remove
  Background), `PerspectiveDetector.detect(in:)` (Perspective Auto),
  `RedEyeDetector.detect(in:)`, `ImageEncoder`'s encode for `.heic` and
  `.avif`, `MultiPageWriter.finish` for animated HEIC, and `VideoFrames`'
  two AVFoundation waits.
- **`BatchConverter.encodedData`** encodes through `BlockingWork`. The app
  already ran Batch Convert, the Shortcuts Convert and Resize actions and
  Create Web Gallery under `BatchWorkExecutor` (GCD), so they were safe;
  but the converter is public API and the tests called it straight from the
  pool, where the debug check caught it. It is now safe from any caller,
  for an extra GCD hop per file (microseconds).
- **`FileWriteQueue.trash`** records the moves in the catalog through
  `BlockingWork` instead of `Task.detached`. A synchronous SQLite write
  doesn't wait on a GCD queue, so this one was slow-not-stuck, but it was
  blocking work on the pool all the same.

Design decision: the helpers stay synchronous rather than gaining `async`
twins. Every production caller already reaches them from GCD (BlockingWork,
`BatchWorkExecutor`, the thumbnail and pixel-size queues, `concurrentPerform`
inside `BlockingWork`), and the debug check now proves it in the tests
rather than by reading.

### Audit of production call sites (goal 3)

Each was read, and the app suites that drive them (31 suites, 205 tests:
Automation, Batch Convert, contact sheet, desktop picture, duplicates, HDR
editing, montage, multi-page, print, Save, Save As, slideshow video, subject,
corrections, retouch, video browser/viewer/compare/frame save, web gallery,
Live Text, Trash safety) were run with the check printing a stack for every
cooperative call: **none**. "Can run on a cooperative thread" means an async
function or Task reaches the call without `BlockingWork` or another GCD hop.

| Call | Where | On the pool? |
|---|---|---|
| Feature prints (Find Duplicates, similar) | `DuplicatesModel.find` via `BlockingWork.run`; `concurrentPerform` inside it | No |
| Remove Background (`VNGenerateForegroundInstanceMaskRequest`) | `RemoveBackground.swift` `BlockingWork.run { SubjectDetector.mask }` | No |
| Perspective Auto (`VNDetectRectanglesRequest`) | `ViewerCorrections` `BlockingWork.run` | No |
| Red-eye (`VNDetectFaceLandmarksRequest`) | `ViewerRetouch` `BlockingWork.run` | No |
| Live Text (`ImageAnalyzer.analyze`) | async VisionKit API, suspends rather than blocks | No (nothing blocks) |
| Save / Save As / in-place HEIC, AVIF | `SavePresenter.write`, `writeInPlace` `BlockingWork.run` | No |
| Save As size estimate, quality compare | `SaveAsModel`, `QualityCompareView` `BlockingWork.run` | No |
| Batch Convert, Shortcuts Convert/Resize | `BatchConvertJob` under `BatchWorkExecutor`; now also `BlockingWork` inside `encodedData` | No (was safe; now safe for any caller) |
| Web gallery encodes | `writePictures` under `BatchWorkExecutor` | No |
| Multi-page builder, image strip | `BrowserMultiPage` `BlockingWork.run` | No |
| Montage, capture, desktop picture, print page, contact sheet writes | `BlockingWork.run` in each | No |
| Video info, thumbnails, Copy Frame, Save Frame As | `BlockingWork.run` (viewer, preview pane, compare, `SaveSupport`), the pixel-size cache's own queue, the thumbnail service's workers | No |
| Slideshow video export (`AVAssetWriter`) | frames and decodes on the writer's own serial queues; `finishWriting` is the async API. `AVAssetWriter(outputURL:)` and `startWriting()` run on the calling task: brief, and never seen waiting | No waits on the pool |
| `FileWriteQueue.trash` → `catalog.filesMoved` | was `Task.detached` (pool) | Fixed: `BlockingWork` |
| `ImageLoader.raisePriority` `work.item.wait()` | inside `DispatchQueue.global(qos: .userInitiated).async`: a GCD worker, which gives its budget place back | No; unchanged |

### Tests (goals 2 and 4)

- **`.offCooperativePool`** (a `TestScoping` trait, one copy in
  MinivuCoreTests and one in MinivuRenderTests, as `TestTiming` is) runs a
  suite's test cases with a task executor preference for a GCD-backed
  executor: an `OperationQueue` at the default QoS, as wide as the Mac has
  cores, so the suites keep the parallelism the pool gave them and a
  parameterised suite can't start a hundred renders at once. It is the
  same idea as the app's `BatchWorkExecutor`, and `BlockingWork` for a
  whole test. Sync and async test bodies, parameterised cases and
  structured child tasks all run off the pool (checked with
  `isOnCooperativeThread`).
- Applied to the suites that call the helpers on purpose or write HEIC and
  AVIF fixtures synchronously (`TestImages.write(… type: .heic)`,
  `Fixtures.gainMapHEIC`/`pqHEIC`, `CIContext.writeHEIFRepresentation`):
  `ExportAVIFTests`, `ExportEncoderTests`, `ExportFormatTests`,
  `ExportRemoveLocationTests`, `ExportLosslessTransformTests`,
  `MetadataWriterTests`, `MultiPageTests`, `DuplicateFinderTests`,
  `DuplicateBenchmark`, `ExportBenchmark` (Core); `BatchPresetEngineTests`,
  `HDRPipelineTests`, `LiveTextImageTests`, `RedEyeDetectorTests`,
  `CorrectionsTests`, `EditReviewTests` (Render). Main-actor suites
  (`ThumbnailServiceTests`, `RemoveBackgroundTests`, `EditRendererTests`,
  all of MinivuTests' window suites) run on the main thread, which is not
  a cooperative thread, so they need nothing.
- Why a trait rather than rewriting each call as `await BlockingWork.run`:
  HEIC fixtures are written synchronously from dozens of sync test
  functions and shared helpers; the trait covers those and anything the
  check can't see (direct ImageIO calls in test code) with one line per
  suite. The production fixes are what make the app safe; the trait is
  only for tests that block on purpose.
- **`CooperativeStarvationTests.blockingWorkFinishesWhileEveryCooperativeThreadIsBlocked`**
  (the regression test, goal 4): holds every default-QoS cooperative thread
  blocked (the state of the hung run), then starts 2 × cores jobs through
  `BlockingWork`, half AVIF encodes (HEIC where AVIF isn't writable) and
  half feature prints, and waits for them on a plain thread with the
  `TestTiming.patience` deadline (10 s × slack). Healthy: 20 of 20 in about
  0.14 s. Checked against two simulated regressions: `BlockingWork` at the
  default QoS (0 of 20 by the deadline; the watchdog lets the pool go, the
  test records an issue, the run carries on) and the jobs run on the pool
  itself (the pool can't come back; 30 s after the deadline the watchdog
  stops the process with "The cooperative pool is deadlocked: … see
  docs/feature-notes/coop-starvation.md", so the run fails with a reason
  instead of hanging at 0% CPU).
- **`directCallsFromATaskAreLoggedAndBlockingWorkCallsAreNot`**: the
  check itself works (a direct `FeaturePrint.make` in a task is logged,
  the same through `BlockingWork` isn't), so a silent log means something.
- **`CooperativePoolTests.batchConvertEncodesOffThePool`** (Render, HEIC and
  AVIF): `BatchConverter.encodedData` called from the pool, SDR and gain-map
  originals, logs no cooperative call. Fails without the fix (both formats).

## Limits

- The check is debug-only and covers the helpers listed; a new framework
  call that waits on GCD needs its own `expectOffCooperativePool` line.
  Direct ImageIO, Vision or AVFoundation calls in test code aren't seen;
  the rule for tests is to use `.offCooperativePool` or `BlockingWork`.
- `isOnCooperativeThread` relies on GCD's queue labels. Should Apple rename
  them, it answers false everywhere: the check goes quiet, and
  `directCallsFromATaskAreLoggedAndBlockingWorkCallsAreNot` fails to say so.
- Only encodes, Vision and the AVFoundation waits were probed. HEIC
  *decoding* and other frameworks may behave the same; the general rule
  (never block a cooperative thread) covers them, and decoding already goes
  through GCD everywhere in the app.
- The regression test holds the default-QoS pool for its duration (about
  0.15 s when healthy), so tests running beside it pause that long.
- The trait's executor is shared by all marked suites in a target: at most
  one test case per core runs on it at once.

## Where the real documentation should change

- **DESIGN.md §4 (Architecture), new short subsection "Blocking work and the
  cooperative pool"** (or extend wherever `BlockingWork` is first
  described): the macOS 27 measurement (blocked cooperative threads keep
  their GCD budget place; Vision and HEIF/AVIF encoders wait on GCD work at
  the caller's QoS, so enough of them on the pool deadlock it), the rule
  (never block a cooperative thread on these, at any QoS; `BlockingWork` or
  `BatchWorkExecutor`), and the debug check `expectOffCooperativePool`. It
  sits naturally beside "Core Image on macOS 27" in §8 as another measured
  macOS 27 behaviour.
- **DESIGN.md §6 (Efficiency rules), rule 1**: add that blocking work goes
  through `BlockingWork`, not the cooperative pool, because there it can
  deadlock, not only slow things down.
- **docs/wiki/Architecture.md, "Concurrency"**: extend the `BlockingWork`
  bullet with the deadlock and the debug check; **"Tests"**: tests that call
  Vision or HEIF/AVIF encoders directly, or write HEIC fixtures, use the
  `.offCooperativePool` trait; mention the regression test and update the
  test count.
- **docs/wiki/Troubleshooting.md** (developer section, if any): "the test
  run hangs at 0% CPU" → a test blocking cooperative threads on Vision or
  HEIF/AVIF; look for `minivu: … blocked a cooperative thread` on standard
  error.
- No help page or keyboard-shortcuts change: nothing user-visible.
