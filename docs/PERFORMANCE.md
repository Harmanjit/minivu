# minivu performance: what is slow, why, and the plan to fix it

This document has five parts:

1. a summary
2. how the numbers were measured
3. what takes how long
4. the speed-up plan
5. how to keep minivu fast once it is fixed

Every number comes from the study of 15 November 2026. The study measured a
release build of `feature/perf` (commit e8ce456) on one Mac. A second person
then reran the most surprising entries and checked the arithmetic (the
"review"). Where the review found a number was wrong, this document uses the
corrected one and says so.

Most numbers are in milliseconds (ms). 1,000 ms is one second.

---

## 1. Summary

### The most important findings

1. **Everyday viewing is already fast.**
   - Going to the next photo takes 7.8 ms when minivu has loaded it ahead of
     time, and the previous photo takes 9.0 ms.
   - Opening a JPEG in the viewer takes 50 to 59 ms.
   - Opening a folder of 1,000 files takes 44 ms.
   - None of these needs work.

2. **The worst freeze comes from renaming or moving many files while their
   folder is on screen.**
   - Renaming 1,000 files keeps the main thread busy for 369 ms. The longest
     single freeze is 131.7 ms. (The *main thread* is the one thread that
     draws the window and answers clicks. While it is busy, the app cannot
     respond.)
   - Moving 1,000 files into the folder on screen keeps the main thread busy
     for 200 ms.
   - The cause is small and fixable. For every changed file, minivu asks the
     file system to tidy up its path, on the main thread, again and again.

3. **Sorting by rating, or filtering by camera details, is slow the first
   time you do it on a folder of camera files.**
   - It takes 2.8 to 3.5 seconds for 1,000 photos.
   - minivu reads each file's *header* (the small block of details at the
     start of an image file) one file after another, on one thread. Nine
     other cores sit idle.

4. **The RAW exposure slider stutters.**
   - Each frame takes 83.7 ms. Smooth movement needs 16 ms or less (60 frames
     a second), so this is about five times too slow.
   - Every slider frame develops the RAW file again at full preview size.
   - The lighting slider, for comparison, takes 6.1 ms a frame.

5. **Batch Convert does far more work than it needs when it shrinks photos.**
   - Converting 20 photos to 2,048 px JPEGs takes 1,506 ms.
   - Per photo, preparing the pixels takes 150 ms and writing the JPEG only
     13.2 ms.
   - The photo is decoded at its full 24 megapixels and then shrunk. Peak
     memory reaches about 1,057 MB.
   - The web gallery uses the same code, at 2,753 ms for 20 pictures.

6. **HDR photos with a gain map open about four times slower than ordinary
   JPEGs.**
   - They take 205 to 207 ms against 50 to 59 ms.
   - 15.5 ms of that is spent only on checking *whether* the photo is HDR.
   - A *gain map* is a hidden second picture inside the file that tells the
     screen how much brighter each part may go. Modern iPhone photos carry
     one.

7. **Big folders open in about half a second, and a third of that is
   wasted.**
   - 10,000 files take 270 ms in the window and 20,000 take 538 ms.
   - About a third of the open is a pass that checks a cache of ratings. On
     the first open after launch that cache is empty, so the pass finds
     nothing, but it still pays to look up every file on disk.

8. **Memory use is higher than the documentation says, and has never been
   checked on an 8 GB Mac.**
   - Scrolling through 5,000 thumbnails peaks at 281 MB. The wiki says about
     186 MB, measured on an older Mac. Nobody has explained the gap.
   - Batch Convert peaks at about 1 GB.
   - The rules that are meant to keep 8 GB Macs safe have never been
     measured.

### The top five actions

| # | Action | What it fixes | Size |
|---|---|---|---|
| 1 | Tidy each folder path once per batch instead of once per file, and send one change notice per batch | the 131.7 ms and 45.2 ms freezes when renaming or moving files | small |
| 2 | Read file headers on four threads at once | the 2.8 to 3.5 s rating sort and metadata filter, and Find by camera details | small |
| 3 | Skip the disk lookup in the ratings cache when the cache is empty, and look in the cache before touching the disk | a third of big-folder open time | small |
| 4 | Decode at a smaller size when Batch Convert or the web gallery is shrinking photos | 150 ms per photo in Batch Convert, and about 1 GB of memory | medium |
| 5 | Develop RAW files at half size while a slider is being dragged, then at full size when it is let go | the 83.7 ms RAW slider frame | medium |

Before any of these, the benchmark kit itself needs a few small fixes
(phase 0 in section 4), so that the before-and-after numbers can be trusted.

---

## 2. How this was measured

### The machine and the build

| item | value |
|---|---|
| Mac | MacBook Air (Mac16,13), Apple M4, 16 GB. It has 4 *performance cores* (fast) and 6 *efficiency cores* (slower, use less power). It has no fan, so long runs can slow down as it warms up. |
| macOS | 27.2.1 |
| Tools | Xcode 27.2, Swift 6.4.2 |
| Build | release, built once: `swift build -c release --build-tests -Xswiftc -enable-testing -j 4` |
| Photos | the real test photos in `~/latent/TestAssets`, only ever read |
| Catalog | kept in memory (`MINIVU_CATALOG=memory`), so nothing touched the real one |
| Screen | the built-in 2880 × 1864 display only. Viewer textures were sized to it (1508 × 1008). |
| Metal shaders | not precompiled, because the Metal toolchain is not installed. They are compiled when the app starts. |

To get a release test build at all, two test files needed an `#if DEBUG`
guard. That change is in the worktree but not committed. No app code
changed.

### The method

- **Benchmarks.** `scripts/bench.sh` runs each benchmark in a process of its
  own, one after another. Each benchmark prints a `BENCH` line with its
  *median* (the middle value, so half the runs were faster and half slower)
  and its *p90* (90% of runs were at least this fast, so it shows the slow
  tail).
- **Main-thread time.** The window benchmarks also report how long the main
  thread was busy, to about 1 ms, counting only busy spells of 2 ms or more.
- **Runs.** Every benchmark ran twice. Where the two runs differed by more
  than 15%, it ran a third time and the middle of the three was used.
  Otherwise the two were averaged.
- **Profiles.** Instruments' Time Profiler recorded where the time went. A
  *profile* samples every thread once a millisecond and notes which function
  it is in, so you can see which code the time is spent in.
- **Signposts.** minivu marks the start and end of each step with
  *signposts* (named markers that Instruments can show on a timeline). They
  split each operation into phases, for example "decode" and "upload".

### The machine was not quiet

Other Claude sessions were building and testing another project on the same
Mac for most of the day. That steals CPU and makes numbers worse. To deal
with it:

- The first full pass overlapped those builds, so it was thrown away.
- Every later benchmark waited until no other build or test was running. If
  one started part-way through, the benchmark was thrown away and rerun, up
  to three times.
- A run that was still disturbed after three tries is called *contended*.

### Corrections from the review

The review recomputed every number in the tables and found no arithmetic
mistakes. It did find four problems, and this document takes them into
account:

1. **Sort by rating and the metadata filter were too slow in the tables.**
   Two of their three runs were contended, and the "middle of three" landed
   on a contended one (4,535 and 3,965 ms). The clean runs are 2,848 to
   3,498 ms for sort by rating and 3,030 to 3,528 ms for the metadata filter.
   This document uses only the clean runs.
2. **Opening a JPEG or HEIC in the viewer gives two different answers.** Some
   runs come out at 50 ms (JPEG) and 66 ms (HEIC). Others come out at 59 and
   74 ms. Both groups were seen twice. This document gives both.
3. **The older decode benchmarks ran three at a time.** The filter for
   `DecodeBenchmark` also caught `FitBenchmark` and `RawBenchmark`, so they
   ran side by side and slowed each other down. Their numbers are not used
   anywhere in this document.
4. **Batch Convert's phase split from Instruments is wrong.** Instruments
   pairs up the start and end markers wrongly when two photos are processed
   at once (render 85 + encode 124 comes to more than the 145 ms total). This
   document uses the benchmark's own per-photo numbers instead.

### Caveats: what these numbers do not tell you

- **One Mac.** Everything was measured on one M4 MacBook Air with 16 GB.
  Nothing was measured on an 8 GB Mac or an older chip.
- **The disk was always warm.** macOS keeps recently read files in memory
  (the *page cache*). Every "cold" run in this study still read files that
  were already in the page cache. "Cold" here means that minivu's own caches
  were empty, not that the disk had to be read. A first look at a folder
  after a restart will be slower.
- **The real app launch was not measured.** Only the parts of launch that run
  inside the test process were timed.
- **The catalog was in memory.** The cost of writing the catalog to disk was
  not measured.
- **Some labels are misleading.**
  - The "cold" and "warm" ratings-cache passes do exactly the same work, so
    their times match (8.87 and 9.00 ms).
  - Thumbnail "decode each" times were measured with 8 decodes running at
    once, partly on efficiency cores, so one decode on its own is faster.
  - The video thumbnail test uses a short made-up clip, so it is not typical.
  - Find in the browser's `filter_ms` (3,438) is larger than the whole run
    (3,037 ms) because it adds up time from overlapping threads.
  - The first-screen thumbnail test shows 12 cells, not a full grid of 60.
- **Older figures disagree and nobody has explained why.**
  - Grid scroll peak memory: 281 MB now, about 186 MB in the wiki.
  - Reading a header cold: 11 ms per file (feature notes), 5.5 ms (older
    benchmark), 2.93 ms (`find.metadataCold`).
  - Feature prints for similar-photo search: 14.2 ms each (older benchmark)
    against 4.9 ms each (`duplicates.similarCold`).

### How to re-run

```sh
cd ~/minivu-worktrees/perf
scripts/bench.sh /tmp/bench.txt                    # build, then every entry
SKIP_BUILD=1 scripts/bench.sh /tmp/bench.txt ViewerBenchmark   # one entry, reusing the build
```

- The results go to the file you name. The full test output goes beside it,
  with `.log` added.
- `MINIVU_BENCH_DIR` points at another photo folder.
- `MINIVU_BENCH_QUICK=1` checks that the kit works. Its numbers mean nothing.
- Close other apps and do not build anything else while it runs. The waiting
  and rerunning scripts used in this study (`gated.sh`, `busy.sh`,
  `compare.py`) are not in the repository yet. Phase 0 moves them in.

---

## 3. What takes how long

**How to read the "feels" column:**

| feels | time |
|---|---|
| instant | under 50 ms |
| quick | under 200 ms |
| noticeable | under 1 second |
| slow | 1 second or more |

Some things repeat on every frame, such as dragging a slider. For those the
bar is much lower: 16 ms per frame, or the movement stutters. Those rows say
"smooth" or "stutters" instead.

"Main ms" is the main-thread time, where it was measured. Times are medians
unless the row says otherwise.

### Launch

| what | median ms | p90 ms | feels | where the time goes |
|---|---:|---:|---|---|
| open an existing catalog (20,000 rows) | 0.25 | 0.28 | instant | |
| create a new catalog | 2.34 | 2.70 | instant | |
| open the thumbnail store (5,000 rows) | 0.22 | 0.27 | instant | |
| restore 10 folder bookmarks | 2.19 | 2.40 | instant | |
| sidebar library query | 2.46 | 2.56 | instant | |
| collections menu query | 2.41 | 2.49 | instant | |
| GPU warm-up | 1.32 | 8.35 | instant | 40.8 ms the first time in a process, because the shaders compile then. It already runs off the main thread. |
| browser window shown | 86.23 | 92.39 | quick | 210.1 ms the first time in a process. The window, not the databases, is the launch cost. |
| thumbnail-store prune scan | 4.08 | 4.43 | instant | already in the background |
| thumbnail-store prune (delete a tenth of 5,000 rows, 173 MB) | 386.27 | 395.12 | noticeable, but in the background | one big delete that holds the store's only lock |

### Folder

| what | median ms | p90 ms | main ms | feels | where the time goes |
|---|---:|---:|---:|---|---|
| open 1,000 files in the window | 44.42 | 46.06 | 11.3 | instant | |
| open 10,000 files in the window | 269.83 | 277.27 | 12.6 | noticeable | ratings-cache pass 41% (path tidying 34%), listing 20%, sorting 19% |
| open 20,000 files in the window | 538.16 | 542.12 | 20.0 | noticeable | same as above |
| open 10,000 files (no window), phases | 275.0 | | | noticeable | ratings-cache pass 96.9, list 59.3, sort 56.3, catalog query 36.6, heal 8.2, finish 3.4 |
| open 20,000 files (no window), phases | 566.4 | | | noticeable | ratings-cache pass 194.8, list 119.4, sort 117.7, catalog query 75.3 |
| reload 10,000 files | 277.99 | 282.76 | 6.2 | noticeable | |
| reload 20,000 files | 568.98 | 573.21 | 15.8 | noticeable | |
| flat view of 20,000 files in a tree | 513.88 | 516.90 | 17.0 | noticeable | |
| ratings-cache pass, 1,000 / 10,000 / 20,000 files | 8.87 / 94.37 / 188.49 | | | instant / quick / quick | one disk lookup (`lstat`) and one path tidy per file, even when the cache is empty |
| sort 20,000 by name | 115.43 | 118.69 | | quick | string comparison |
| catalog ratings query, 20,000 files | 42.59 | 43.58 | | instant | |
| read 500 pixel sizes | 40.92 | 41.12 | | instant | |
| **sort 1,000 camera photos by rating** (clean runs) | **2,848 to 3,498** | | 20.1 | **slow** | reading headers one at a time: about 569 to 705 ms per 200 files. Ratings 54%, filter details 44%, nearly all in the RAW header reader. |
| **filter 1,000 camera photos by metadata** (clean runs) | **3,030 to 3,528** | | 18.8 | **slow** | same as above |

The main thread is only busy for about 20 ms during the rating sort and the
filter, so the window still responds. You just wait about 3 seconds for the
grid to re-sort.

### Thumbnails

A *screenful* here is 60 cells. *Cold* means minivu's thumbnail cache was
empty. *Warm* means the thumbnails were already saved.

| what | median ms | p90 ms | main ms | feels | where the time goes |
|---|---:|---:|---:|---|---|
| JPEG screenful, cold | 231.26 | 237.72 | | quick | the JPEG decoder (97%) |
| NEF screenful, cold | 218.38 | 230.68 | | quick | decoding the JPEG preview inside the RAW file |
| video screenful, cold (made-up clip) | 135.37 | 143.23 | | quick | starting the video pipeline |
| HEIC screenful, cold | 1,199.17 | 1,238.40 | | slow | the hardware decoder; minivu waits on it 31% of the time |
| 24 MP PNG screenful, cold | 3,202.06 | 3,356.29 | | slow | a full PNG decode (PNG cannot decode at a smaller size), then a shrink. Large photo PNGs are rare. |
| any format, warm | 4.09 to 6.26 | | | instant | |
| save one thumbnail / read one back | 0.04 / 0.13 | | | instant | the store's lock is never waited on (0.00 to 0.01 ms) |
| first screen in the window (12 cells), cold | 108.38 | 127.84 | 28.8 | quick | |
| first screen in the window (12 cells), warm | 28.43 | 32.41 | 18.0 | instant | longest freeze 16.0 ms, cause not profiled |

### Viewer

| what | median ms | p90 ms | main ms | feels | where the time goes |
|---|---:|---:|---:|---|---|
| open a JPEG | 50 or 59 (two groups) | 60.27 | 24.2 to 27.8 | instant to quick | decode 21.4, upload 5.2. Building the window takes about 13.6 ms per open before the decode even starts. |
| open a HEIC | 66 or 74 (two groups) | 75.66 | 20.9 to 26.1 | quick | decode 40.1, upload 5.8 |
| open a NEF (its built-in preview) | 62.43 | 64.98 | 27.0 | quick | preview 35.2, plus two side header reads of 7.5 and 7.0 |
| open a NEF with Render RAW | 210.99 | 229.62 | 25.9 | noticeable | the RAW develop, 186.9 |
| open an HDR gain-map photo | 206.69 | 213.10 | 28.2 | noticeable | decode 133 to 151, HDR check 15.5, upload 36.0 (CPU drawing 34.1) |
| next photo, already loaded | 7.79 | 13.06 | 7.7 | instant | the flip itself is 3.1 ms |
| next photo, not loaded yet | 43.86 | 49.39 | 6.8 | instant | the decode and upload |
| previous photo | 9.02 | 18.69 | | instant | |
| zoom to 100%, JPEG / HEIC / NEF | 118.64 / 153.88 / 133.17 | | | quick | the full-size decode. The screen picture is zoomed straight away and sharpens when this arrives. |
| Compare two photos | 59.41 | 61.04 | 46.0 | quick | main thread longest freeze 44.9 ms, not profiled |
| Compare four photos | 92.27 | 97.44 | 62.6 | quick | main thread longest freeze 63.9 ms, not profiled |

A *texture* is a picture held in the graphics chip's memory, ready to draw.
*Upload* is copying the decoded picture into a texture.

### Edit

| what | median ms | p90 ms | feels | where the time goes |
|---|---:|---:|---|---|
| get a JPEG ready to edit | 110.32 | 119.07 | quick | load 79.4, then the smaller working copy 31.1 |
| get a HEIC ready to edit | 135.67 | 148.31 | quick | load 106.0, working copy 29.5 |
| get a NEF ready to edit | 115.00 | 120.80 | quick | load 82.9, working copy 32.3 |
| lighting slider, per frame | 6.11 | 8.22 | smooth | the graphics chip, cheap |
| full render with lighting | 15.04 | 18.56 | instant | |
| **RAW exposure slider, per frame** | **83.73** | 85.88 | **stutters** | develops the RAW again on every frame (76 ms) |
| full render with RAW exposure | 127.31 | 149.16 | quick | |
| crop drag, per frame | 6.68 | 38.95 | smooth, with stutters | 6 rebuilds of the working copy per 24-frame drag, 29.1 ms each, so about 1 frame in 4 stutters |

The *working copy* (the code calls it the *proxy*) is a smaller version of
the photo that the sliders draw from, so they stay fast.

### Save and export

| what | median ms | p90 ms | feels | where the time goes |
|---|---:|---:|---|---|
| save a JPEG in place | 102.80 | 104.12 | quick | the JPEG encoder 79.5 |
| save a HEIC in place | 113.85 | 117.22 | quick | the HEIC encoder 100.9 |
| Save As AVIF | 309.87 | 320.37 | noticeable | the AVIF encoder 253.2 |
| slideshow video, 10 slides | 5,576.55 | 5,633.05 | slow | drawing 1.07 s, decoding 711 ms, captions 108 ms; about 4 s not yet explained |

Saving already happens off the main thread.

### Files

| what | median ms | p90 ms | main ms | feels | where the time goes |
|---|---:|---:|---:|---|---|
| copy 1,000 files (folder not shown) | 333.11 | 337.28 | 7.9 | noticeable, in the background | the file system's clone call |
| move 1,000 files (folder not shown) | 226.51 | 230.66 | 8.1 | noticeable, in the background | the file system's rename call |
| **move 1,000 files into the folder on screen** | 424.24 | 439.62 | **200.1** | noticeable, with freezes up to 45.2 ms | 1,002 change notices; tidying paths is 82% of handling them |
| **Batch Rename 1,000 files** | 621.76 | 690.98 | **369.2** | noticeable, with a 131.7 ms freeze | path tidying, plus clearing thumbnail entries (30%) |
| move 100 of 1,000 files to the Bin | 42.36 | 49.22 | 35.1 | instant, but a 31.3 ms freeze | |
| 20 writes of 8 MB queued | 54.71 | 64.86 | | instant | |

### Batch and tools

| what | median ms | p90 ms | feels | where the time goes |
|---|---:|---:|---|---|
| info panel fields | 0.09 to 0.56 | | instant | |
| Count Colors (24 MP), count | 26.66 | 26.77 | instant | |
| Count Colors, decode | 62.08 | 65.62 | quick | |
| **Batch Convert 20 photos to 2,048 px JPEG** | **1,506.24** | 1,583.14 | slow | per photo: render 150 ms, encode 13.2. Profile: loading the source is 78%, a full 24 MP decode and draw. Peak 1,057 MB. |
| Batch Convert 20 to full-size HEIC | 2,202.39 | 2,317.03 | slow | render 75.3, encode 143.8 per photo; colour conversion for the hardware encoder |
| Batch Convert 20 to full-size AVIF | 5,359.27 | 5,492.98 | slow | Apple's software AVIF encoder, 78% of all samples; encode 504.1 per photo |
| Batch Convert to 2,048 px, replacing the originals | 1,515.43 | 1,560.88 | slow | same as the 2,048 px row |
| web gallery of 20 pictures | 2,753.02 | 2,905.43 | slow | about 138 ms per picture, through the same code as Batch Convert, one picture at a time |

### Find and duplicates

| what | median ms | p90 ms | feels | where the time goes |
|---|---:|---:|---|---|
| walk 20,000 files | 126.86 | 129.08 | quick | |
| find by name in 20,000 files | 138.17 | 139.33 | quick | |
| find by camera details, 120 files, first time | 346.71 | 352.32 | noticeable | header reads, 2.93 ms each, one at a time |
| the same, details already saved | 2.04 | 2.28 | instant | |
| Find in the browser, 1,000 files, first time | 3,037.11 | 3,077.82 | slow | 1,000 header reads, one at a time |
| the same, details already saved | 35.59 | 35.71 | instant | |
| exact duplicates, 100 files, first time | 11.83 | 12.04 | instant | |
| similar photos, 200 files, first time | 536.79 | 545.54 | noticeable | 4.9 ms per feature print, with 2 workers |
| similar photos, saved | 5.54 | 5.59 | instant | |

### Memory

*Footprint* is how much memory macOS counts against minivu. "MB" is megabytes.

| what | start MB | peak MB | end MB | notes |
|---|---:|---:|---:|---|
| scroll through 5,000 thumbnails (466 screens) | 40 | 281 (280 in the review) | 267 | 86.94 ms per screen, main thread 8.2 ms. The wiki says about 186 MB. |
| flip through 20 photos as fast as they arrive | 14 | 380 | 374 | more than the screen textures alone should need; not yet explained |
| Batch Convert to 2,048 px (2 at a time) | | 1,057 to 1,069 | | |
| Batch Convert to HEIC | | 1,032 to 1,081 | | |
| Batch Convert to AVIF | | 1,150 to 1,173 | | |
| slideshow video | | 376 | | |
| Count Colors | 14 | 274 to 285 | | |

RAW develop memory depends on the Core Image memory limit. These come from
one run each, and memory carries over from one file to the next, so treat
them as rough:

| limit | extra MB, three NEFs | render ms, three NEFs |
|---|---|---|
| none | 1,156 / 2,825 / 2,882 | 377, 291, 263 |
| 256 MB | 698 / 1,250 / 1,276 | 366, 292, 277 |
| 512 MB (the 8 GB setting today) | 996 / 2,104 / 2,155 | 348, 243, 250 |
| 1,024 MB | 1,231 / 2,389 / 2,490 | 328, 253, 237 |

---

## 4. The speed-up plan

Three draft plans looked at the same measurements in different ways: how
fast things feel, how fast bulk work runs, and memory and energy. This plan
merges them. Where they disagreed, the measurements decided.

**Sizes:**

- **S (small):** one or two files, no new design.
- **M (medium):** several files, new tests, some design.
- **L (large):** a new pipeline.

**Words used below:**

- *File:line* references point at the measured code in
  `~/minivu-worktrees/perf`. On `main` the line numbers are a few lines off,
  because the signposts are missing there.
- An *expected gain* is an estimate worked out from the measured numbers.
  None of them has been measured yet. Each item says how to measure it.
- *Verify* means rerunning the named benchmark, with clean runs only, and
  checking it against the target.

### Phase 0: make the measurements trustworthy (do this first)

These changes do not speed up the app. They make the before-and-after
numbers worth believing.

**0.1 Make the release test build compile, and keep it compiling (S)**
- *Problem:* `swift build -c release --build-tests` fails, because two tests
  use a debug-only helper (`BlockingWork.CallLog`).
- *Change:*
  - Commit the two `#if DEBUG` guards already in the worktree
    (`CooperativeStarvationTests.swift`, `CooperativePoolTests.swift`).
  - Add a release `--build-tests` step that only compiles to
    `.github/workflows/ci.yml`. CI builds debug only today.
- *Verify:* CI fails if a debug-only helper is used in a release test again.

**0.2 Give each signpost its own ID (S)**
- *Problem:* `Perf.begin` starts every interval without an ID
  (`Perf.swift:43-46`). So when the same step runs on several threads at once
  (thumbnails, header reads, Batch Convert, decode), Instruments pairs starts
  and ends wrongly. That is why the Batch Convert phase split was wrong.
- *Change:* pass `signposter.makeSignpostID()` for each interval. It costs
  nothing when nobody is recording.
- *Verify:* in a Batch Convert trace, render plus encode no longer comes to
  more than the per-file total.

**0.3 Stop the older benchmarks running side by side (S)**
- *Problem:* `DecodeBenchmark`, `FitBenchmark` and `RawBenchmark` are
  top-level suites, so one filter ran all three at once. Their results
  differed by up to 32% from a run on their own.
- *Change:* nest them under the serialized `Benchmarks` parent, or make each
  filter match exactly one suite.

**0.4 Put the waiting and rerunning into bench.sh (S)**
- *Change:*
  - Move `gated.sh` and `busy.sh` into `scripts/`.
  - Before each entry, wait for no other build or test to be running.
  - While it runs, watch for one starting, and rerun the entry if one does.
  - Work out medians from clean runs only. Print a row with fewer than two
    clean runs as UNRELIABLE.
  - Where results fall into two groups (viewer JPEG and HEIC open), report
    both groups instead of one median.
- *Verify:* two back-to-back runs of the entries that disagreed today agree
  within 15%.

**0.5 Record peak memory where it is missing (S)**
- *Change:* add `peak_mb` to the cold PNG and HEIC thumbnail runs, to zoom to
  100%, and to the web gallery.

### Phase 1: quick wins (all small)

**1.1 Tidy each folder path once per batch, not per file (S)**
- *Measured problem:*
  - Moving 1,000 files into the folder on screen: 200.1 ms of main-thread
    time, of which handling change notices is 197.14 ms over 1,002 notices.
    Longest freeze 45.2 ms.
  - Batch Rename of 1,000 files: 369.2 ms of main-thread time, longest freeze
    131.7 ms. The profile shows 12 change notices with a 92 ms median, and
    941 ms of the 1,006 ms inside them is spent in `samePath`.
  - In the move profile, `samePath` is 82% of the notice handling, and the
    path tidying underneath it is 78%.
- *Cause:*
  - `BrowserModel.swift:1588-1590`: `samePath` tidies *both* paths through the
    file system (`standardizedFileURL`) every time it is called.
  - It is called for each changed file in `catalogChanged`
    (`BrowserModel.swift:1068-1074`), and again through `isShown`
    (`BrowserModel.swift:986-990`). The folder on screen is tidied again on
    every call, even though it never changes.
- *Change:*
  - Store the folder's tidied path once, when the folder is shown.
    `BrowserModel.swift:478` already tidies it; keep the result.
  - Inside `catalogChanged`, remember the answer for each parent folder in a
    small dictionary. The files in one batch nearly always share one or two
    parent folders, so this becomes one or two lookups per batch instead of
    up to four per file.
  - The behaviour stays exactly the same. Paths like `/tmp` and
    `/private/tmp` are still treated as the same, because each distinct
    folder is still tidied once.
  - Look at `BrowserManagement.swift:262` and `BrowserBatch.swift:247` too,
    which filter by folder the same way.
- *Expected gain:* Batch Rename's main-thread time drops from 369.2 ms to
  roughly 190 ms, and the 131.7 ms freeze goes. Item 1.2 removes most of the
  rest of the move cost.
- *Risk:* low. These are reads only, so no data is at risk. Test a folder
  reached through a symbolic link, and `/tmp`.
- *Effort:* S.
- *Verify:* `files.rename1000` (main thread ≤ 200 ms) and
  `files.move1000Shown` (`catalogChanged_main_ms` ≤ 100).

**1.2 Send one change notice per batch, not one per file (S)**
- *Measured problem:* moving 1,000 files sends 1,002 change notices
  (`catalogChanged_calls`). The profile counts 6,012 notice handlers and
  6,001 sidebar reloads on the main thread.
- *Cause:*
  - `FileTransfer.swift:163-165` moves or copies one file at a time, and each
    file gets its own catalog transaction. (A *transaction* is a group of
    database changes that are saved together or not at all.)
  - `Catalog.post` (`Catalog.swift:1028-1031`) then sends a separate notice
    to the main thread for each one.
- *Change:*
  - Keep one transaction per file, so ratings still follow each file even if
    the move is cancelled half-way.
  - Only combine the *notices*: `post` adds the files to a waiting list, and
    sends one notice to the main thread if none is already on its way. That
    notice carries every file on the list.
  - Do the same for `postLibraryChange`.
- *Expected gain:* main-thread time for moving 1,000 files into the folder on
  screen drops close to that of a move with no window (8.1 ms).
- *Risk:* low. The listeners (the viewer at
  `ViewerWindowController.swift:244`, Compare at
  `CompareWindowController.swift:95`) already accept a list of files. They
  run at most one turn of the run loop later. Check that no test counts
  notices.
- *Effort:* S.
- *Verify:* `files.move1000Shown`: main thread ≤ 30 ms, longest freeze under
  16 ms, notices in single figures, total close to `files.move1000`
  (226.51 ms). `files.copy1000` and `files.move1000` should not change.

**1.3 Clear thumbnail entries in one go after a rename (S)**
- *Measured problem:* in Batch Rename of 1,000 files, clearing thumbnail
  entries takes 74.62 ms on the main thread. The profile puts
  `ThumbnailService.invalidate` → `Set.filter` at 30% of main-thread time.
- *Cause:*
  - `ThumbnailService.swift:214` rebuilds the whole set of failed decodes on
    every call. So each call costs more the bigger that set is, and 1,000
    calls multiply it.
  - Each call also sends its own delete to the thumbnail store.
  - It is called twice per renamed file (`BrowserBatch.swift:235-240`,
    `BrowserManagement.swift:243-248`).
  - The benchmark may have more failed decodes than a normal session, so the
    real cost may be lower.
- *Change:*
  - Keep failed decodes in a dictionary keyed by path, so removing one is a
    single step.
  - Add `invalidate(_ urls: [URL])`: take the lock once, and send one store
    transaction for the whole list. Use it from both call sites.
- *Expected gain:* about 70 ms less main-thread time per 1,000-file rename.
- *Risk:* low. The generation counter must still go up before any running
  thumbnail job can deliver an old picture.
- *Effort:* S.
- *Verify:* `files.rename1000`: `invalidate_main_ms` ≤ 5. Together with 1.1,
  main thread ≤ 130 ms and longest freeze under 33 ms.

**1.4 Read file headers on four threads at once (S)**
- *Measured problem:*
  - Sort by rating: 2,848 to 3,498 ms for 1,000 camera photos (clean runs).
    About 569 to 705 ms per chunk of 200 files, so about 3 ms per file, one
    after another.
  - Metadata filter: 3,030 to 3,528 ms (clean runs).
  - Find in the browser by camera details: 3,037 ms for 1,000 files.
  - Find by camera details: 346.71 ms for 120 files.
  - Profile: reading ratings 54%, reading filter details 44%, both mostly
    inside the RAW header reader.
- *Cause:*
  - `BrowserModel.swift:1180-1196` (`readWantedFileMarks`) reads each file of
    a chunk in a plain loop, on one thread.
  - `CatalogLibrary.swift:95-111` (`loadFilterMetadata`, also used by Find
    through `ImageSearch.swift`) does the same.
  - The reads do not depend on each other, and the ratings cache already
    takes a lock, so they are safe to run side by side.
- *Change:*
  - Inside each chunk, read the files with
    `DispatchQueue.concurrentPerform`, at most 4 at a time (or half the cores,
    whichever is smaller), at utility priority so thumbnails still go first.
  - Write the results into an array by position, then merge.
  - Keep one catalog write per chunk, so the database still sees one
    transaction per chunk.
  - Keep checking the cancel flag for each file.
  - On a volume minivu marks as slow (spinning or network disk), use 2.
- *Expected gain:* about three times faster on the 4 performance cores. Sort
  by rating and the metadata filter about 1 second, Find in the browser about
  1 second, Find about 120 ms. Nobody has checked yet whether the RAW header
  reader speeds up with more threads, so measure it.
- *Risk:* low. Headers are small, so memory is not a concern on 8 GB Macs.
  Thumbnail workers may run at the same time, which is why it is capped at 4.
- *Effort:* S.
- *Verify:* clean runs only, because this benchmark is very sensitive to
  other work (one disturbed run took 7,193 ms).
  - `folder1000Photos.ratingSortOpen` ≤ 1,200 ms, `chunk_ms` ≤ 220
  - `metadataFilterOpen` ≤ 1,300 ms
  - `findInBrowser1000.metadataCold` ≤ 1,200 ms
  - `find.metadataCold` ≤ 140 ms
  - main-thread time unchanged at about 20 ms

**1.5 Big folders: check the ratings cache before touching the disk (S)**
- *Measured problem:* the ratings-cache pass is about a third of opening a
  folder: 9.2, 96.9 and 194.8 ms at 1,000, 10,000 and 20,000 files, out of
  27.4, 275.0 and 566.4 ms. In the window it is 41% of the open, and path
  tidying is 34%.
- *Cause:*
  - `FileMarks.swift:229-236`: `cachedMarks` first looks the file up on disk
    (`lstat`), then tidies its path (`FileMarks.swift:272`), and only then
    looks in the cache.
  - It runs for every image without a catalog row
    (`BrowserModel.swift:772-783`).
  - The cache lives only in memory. So on the first open after launch it is
    empty, and every lookup pays for both steps and finds nothing.
- *Change:*
  - Add `cachedMarks(forNames:inFolder:)`. It tidies the folder once and
    builds each key as folder path + "/" + name.
  - Look in the cache first, and look up the file on disk only if it is
    there.
  - Return straight away if the cache is empty.
  - `marks(for:)` must build its keys the same way, through the same helper,
    so lookups keep matching.
- *Expected gain:* the pass falls to nearly nothing on an empty cache. Opening
  10,000 files in the window goes from 269.83 ms to about 180 ms, and 20,000
  from 538.16 ms to about 350 ms.
- *Risk:* low. An out-of-date entry is still caught by the disk check when it
  is found. Test a `/tmp` folder and a folder reached through a symbolic
  link.
- *Effort:* S.
- *Verify:* `folder10000.openInWindow` ≤ 190 ms,
  `folder20000.openInWindow` ≤ 380 ms, the ratings-cache phase under 10 ms at
  10,000 files. The existing ratings-cache tests must pass.

**1.6 Viewer: start the decode before building the window (S)**
- *Measured problem:* opening a JPEG takes 50 or 59 ms, and a HEIC 66 or
  74 ms. The main-thread profile shows about 13.6 ms per open building and
  showing the window (going full screen 7.6 ms, creating the window 4.5 ms)
  *before* anything asks for the photo's pixels.
- *Cause:* `ViewerWindowController.show` (`ViewerWindowController.swift:31`)
  builds the window first. Then `present` (`ViewerWindowController.swift:305-308`)
  goes full screen before `showCurrent`, which is the first point that asks
  for pixels.
- *Change:* in `show`, before creating the window, ask the image loader to
  start decoding the photo at the screen's size
  (`AppServices.images.prefetch`). When the window asks for it a moment later,
  the loader joins the job already running instead of starting a second one
  (`ImageLoader.swift:369-372`).
- *Expected gain:* about 12 ms off each open. JPEG about 40 to 47 ms, HEIC
  about 55 to 62 ms.
- *Risk:* low. The size asked for must match the size the window works out,
  or the cache will miss. Check this with two displays.
- *Effort:* S.
- *Verify:* `viewer.open_jpeg` under 45 ms in both groups, with main-thread
  time unchanged.

**1.7 Crop drag: don't rebuild the working copy mid-drag (S)**
- *Measured problem:* a crop drag frame takes 6.68 ms at the median, but
  38.95 ms at p90. There are 6 rebuilds of 29.1 ms in each 24-frame drag.
- *Cause:* `EditRenderer.previewPlan` (`EditRenderer.swift:754-768`) asks for
  a rebuild whenever the crop needs more pixels than the working copy has. The
  rebuild runs on the frame that needs it.
- *Change:* while the drag is going on, use the existing working copy scaled
  up, even if it is a little soft. Rebuild once when the drag ends.
- *Expected gain:* p90 from 38.95 ms to about 8 ms. Deep crops look slightly
  soft until you let go.
- *Risk:* low. Only the preview changes. Save and export never use the
  working copy.
- *Effort:* S.
- *Verify:* `edit.cropDragFrame` p90 under 16 ms, at most one rebuild per
  drag.

**1.8 HDR photos: check for a gain map without extracting it (S)**
- *Measured problem:* opening an HDR gain-map photo spends 15.5 ms just
  checking whether it is HDR (out of 15.7 ms of file information). The same
  check runs in Save, Batch Convert, slideshow video and Count Colors.
- *Cause:* `ImageDecoder.hasHDRContent` (`ImageDecoder.swift:643-657`) asks
  ImageIO to copy out the gain map (`CGImageSourceCopyAuxiliaryDataInfoAtIndex`),
  twice, only to find out whether there is one.
- *Change:*
  - Read the file's table of contents instead
    (`kCGImagePropertyFileContentsDictionary` → images → auxiliary data
    types). `embeddedThumbnailLongEdge` (`ImageDecoder.swift:279`) already
    reads that table.
  - Fall back to the current call only when the table has no auxiliary data
    list.
  - Keep the separate PQ/HLG colour-space check.
- *Expected gain:* about 15 ms off every HDR open and every flip to an HDR
  photo, and off each HDR file in Save and Batch Convert.
- *Risk:* HDR detection must stay correct. Test Apple, ISO 21496-1 and Ultra
  HDR files.
- *Effort:* S.
- *Verify:* `HDRPipelineTests` pass, plus a new test with all three kinds of
  gain map. The `decode.hdrCheck` signpost ≤ 1 ms, and
  `viewer.open_hdrGainMap` ≤ 192 ms.

**1.9 Size the thumbnail memory cache to the Mac (S)**
- *Measured problem:*
  - Scrolling 5,000 thumbnails peaks at 281 MB.
  - Reading a whole warm screenful back from the store costs only 6.16 ms,
    and one read 0.13 ms.
  - So holding thumbnails in memory saves only a few ms per screen.
- *Cause (inferred, not measured):* `ThumbnailService.swift:104` keeps up to
  200 MB of thumbnails in memory on every Mac, whatever its size. A long
  scroll fills all of it. This is the likely cause of the high peak.
- *Change:* make the limit depend on the Mac's memory, for example
  physical memory ÷ 128, kept between 48 MB and 128 MB. That gives 64 MB on
  8 GB and 128 MB on 16 GB.
- *Expected gain:* lower peak memory, especially on 8 GB Macs. Scrolling back
  costs one store read per cell, off the main thread.
- *Risk:* low. A smaller cache only means more re-reads, which are cheap.
- *Effort:* S.
- *Verify:* first, check that the cache really is the cause: run
  `memory.gridScroll5000` with the limit lowered and see if the peak moves.
  Then aim for peak ≤ 200 MB, with time per screen within 10% of today's
  86.94 ms. Add a scroll back to the top: main-thread time unchanged.

### Phase 2: bigger gains (medium)

**2.1 Batch Convert and web gallery: decode at a smaller size when shrinking
(M)**
- *Measured problem:*
  - Batch Convert of 20 photos to 2,048 px JPEG: 1,506.24 ms. Per photo,
    render 150 ms and encode 13.2 ms. Peak memory 1,057 MB.
  - Profile: loading the source is 78%. That is a full 24 MP decode (53%) and
    drawing it at full size (73%). The JPEG encode is 7%.
  - Web gallery of 20 pictures: 2,753.02 ms, about 138 ms per picture, through
    the same code.
  - For comparison, the viewer decodes the same JPEG to screen size in
    21.4 ms.
- *Cause:*
  - `BatchConverter.sdrImage` (`BatchConverter.swift:220-237`) goes through
    `renderForExport` → `exportSource` (`EditRenderer.swift:371`) →
    `loadSource` with `forExport` set.
  - That decodes with no size limit (`EditRenderer.swift:940`), so the photo
    is always decoded and drawn at full size. The shrink to 2,048 px happens
    only afterwards.
  - The web gallery takes the same path (`WebGalleryExport.swift:171`).
- *Change:* the two drafts disagreed on how far to go. Only JPEG at 2,048 px
  was measured, so start with the careful version:
  - In `BatchConverter.prepare` (`BatchConverter.swift:194`), spot a resize
    that makes the photo smaller with nothing before it except a rotate or a
    flip.
  - For JPEG and HEIC only, decode at the smallest exact fraction of the full
    size (1/2, 1/4 or 1/8) that is still at least the target size, using
    `ImageDecoder.scaledDecodeSize`. For 6,032 px down to 2,048 or 1,600 px,
    that is 3,016 px. Never decode smaller than the target.
  - Tell the renderer the decoded size really is the source size. Otherwise
    `workingImage` (`EditRenderer.swift:798`) would scale it back up.
  - The existing Lanczos resize then goes from 3,016 px to the target, so the
    output size and resampling filter are unchanged. (*Lanczos* is a
    high-quality way of resizing a picture.)
  - Keep the full decode for PNG and TIFF (they have no cheap smaller
    decode), for format changes only, for any other edit before the resize,
    for enlarging, for RAW, and for HDR output.
- *Expected gain:* render about 150 → 50 ms per photo. Batch Convert to
  2,048 px about 1,506 → 650 to 800 ms. Web gallery about 2,753 → 1,300 to
  1,500 ms. Peak memory much lower: a picture at 3,016 px has a quarter of the
  pixels of the full 6,032 px one.
- *Risk:* output pixels change very slightly. HDR output is untouched.
- *Effort:* M.
- *Verify:*
  - `batch.jpeg2048_20`: median ≤ 800 ms, `render_ms` ≤ 60, `peak_mb` ≤ 600
  - `webGallery.export20` ≤ 1,500 ms
  - `batch.heicFull_20` and `batch.avifFull_20` unchanged
  - a new test comparing old and new output: same size, and a *PSNR* of at
    least 45 dB on the test JPEG and HEIC. (PSNR measures how close two
    pictures are. Higher is closer; 45 dB is very hard to tell apart by eye.)
- *Later:* with less memory per job, 8 GB Macs might be able to run two at a
  time (`BatchConvertJob.swift:81-83`). Only after measuring.

**2.2 Web gallery: make pictures two at a time (S, after 2.1)**
- *Measured problem:* the web gallery takes 2,753.02 ms. Its loop
  (`WebGalleryExport.swift:117-131`) waits for each picture before starting
  the next. Batch Convert already does two at a time on 16 GB Macs.
- *Change:* use a task group limited by
  `BatchConvertJob.defaultConcurrency()` (1 on 8 GB Macs). Keep the pictures
  in their original order for the pages.
- *Expected gain:* about 1.7 times faster on top of 2.1, so about 800 ms.
- *Risk:* memory is limited by the same rule as Batch Convert. Cancelling and
  the skipped-files list must keep working in order.
- *Effort:* S.
- *Verify:* `webGallery.export20` ≤ 900 ms, and peak memory no higher than
  Batch Convert's.

**2.3 RAW slider: develop at half size while dragging (M)**
- *Measured problem:* the RAW exposure slider takes 83.73 ms per frame
  (p90 85.88). The RAW develop alone is 76 ms per frame.
- *Cause:* on every slider frame, `EditRenderer.swift:513-536` develops the
  RAW again at exactly the preview size (3,456 px), with draft mode off
  (`RawDevelop.swift:171`).
- *Change:*
  - While the slider is moving, develop at about half the preview size and
    show it scaled up. Draft mode could be turned on too.
  - When the mouse is let go, or after 150 ms without movement, develop once
    at full quality.
  - Frames must not pile up: only the latest slider value is drawn.
- *Expected gain:* an estimate of 25 to 35 ms per frame while dragging, about
  three times better. This has not been measured. Final quality is the same.
- *Risk:* the picture is visibly softer while dragging, which is normal in
  RAW editors. For HDR RAW, measure the brightness headroom on the final
  develop, not the draft. Memory goes down. Saving always develops at full
  size.
- *Effort:* M.
- *Verify:* split `edit.slider_rawExposure` into a dragging case (median
  under 33 ms, p90 under 40) and a release case (one full develop, about
  80 ms).

**2.4 Viewer: decode the selected photo while the user is still in the
browser (M)**
- *Measured problem:* the same as 1.6. Even after 1.6, the decode and upload
  are on the path between the double-click and the photo.
- *Change:* when the selection has rested on one photo for about 150 ms,
  ask the image loader to prepare it at the viewer's size. Opening it is then
  a cache hit, which the loader hands over at once (`ImageLoader.swift:276-279`).
  Cancel when the selection moves on. Never develop a RAW from the browser.
- *Expected gain:* on a hit, only main-thread work remains: about 25 to 30 ms
  for JPEG and HEIC.
- *Risk:* extra decodes while the user arrows through the grid cost battery,
  so keep the pause and the cancelling. One extra screen texture fits easily
  in the texture cache.
- *Effort:* M.
- *Verify:* a new `viewer.open_afterSelect` benchmark, target under 32 ms.

### Phase 3: larger changes, and things to measure before building

**3.1 Read each file's header once, and save its rating in the catalog (M)**
- *Measured problem:*
  - The metadata filter already saves what it reads: 3,037 ms the first time
    against 35.59 ms once saved (`findInBrowser1000`).
  - Ratings are not saved. So every launch reads every camera file again to
    sort by rating.
  - The viewer also does two side header reads per NEF (7.5 and 7.0 ms), off
    the main thread. They cost battery, not waiting.
  - From the profile, each file may go through the header parser up to three
    times (ratings, filter details, and finding the main picture at 20.5%).
    This is inferred from the call paths, not counted.
- *Cause:*
  - `FileMarksCache` lives only in memory (`FileMarks.swift:217-249`).
  - `MarksXMP.readMarks` (`FileMarks.swift:173`) and `FilterMetadata.read`
    (`SearchCriteria.swift:46`) each open the file separately.
- *Change:*
  - Add rating, pick and sidecar date columns to the catalog's `metadata`
    table. It is a cache table, so the change only adds columns.
  - Fill them from the same read that `FilterMetadata.read` already does.
  - Make the ratings cache look in the catalog before reading the file.
- *Expected gain:* sorting a folder seen before by rating: about 3 s → about
  40 ms, judging by the saved metadata filter. One header read per file
  instead of two or three.
- *Risk:* ratings could go stale if a sidecar file is edited by another app.
  Including the sidecar's date in the check prevents that, as the memory
  cache already does. The catalog change must only add columns.
- *Effort:* M.
- *Verify:* a new warm-catalog rating sort ≤ 100 ms. With both filter and
  rating sort on, one file open per file (count `file.open`). The
  sidecar-change test still re-reads.
- *Do this after 1.4.* If the parallel reads in 1.4 are fast enough, this is
  less urgent.

**3.2 HDR gain-map photos: apply the gain map on the graphics chip (M/L)**
- *Measured problem:* the HDR decode is 133 to 151 ms, and the upload 36.0 ms
  (34.1 of it drawing on the CPU). The ordinary JPEG decode of the same size
  is 21.4 ms.
- *Cause:* the gain map is applied on the CPU at full size, then the result
  is converted again on the CPU for the texture.
- *Change:* for gain-map photos at screen size, decode the ordinary picture at
  screen size and apply the gain map with Core Image on the graphics chip,
  straight into the texture. Keep today's path for PQ/HLG files and as a
  fallback.
- *Expected gain:* an unmeasured estimate of HDR open about 80 ms instead of
  about 206 ms.
- *Risk:* this changes the HDR pipeline. Brightness and tone must match
  today's output. Compare the pixels of both paths.
- *Effort:* M to L.
- *Verify:* `viewer.open_hdrGainMap` under 90 ms, plus a pixel comparison test
  and an HDR on/off display-setting test.

**3.3 Export: drop one full-size CPU drawing step (M, prototype first)**
- *Measured problem:* in Batch Convert to full-size HEIC (2,202.39 ms), an
  ImageIO copy-with-colour-conversion is 45% of the time. For export, the
  decoded picture is then drawn a second time into a bitmap for the graphics
  chip, which is never shown.
- *Change:* two parts, each measured on its own.
  - For export, always use the existing `tiledSource` path
    (`EditRenderer.swift:966`), so the picture goes straight to Core Image.
  - For a full-size decode with no rotation, use
    `CGImageSourceCreateImageAtIndex` instead of the thumbnail call
    (`ImageDecoder.swift:446-449`).
- *Expected gain:* not measured. Build a small benchmark first, and only
  build the change if it saves at least 15%.
- *Risk:* pixels change slightly, because Core Image does the colour
  conversion. Use the same PSNR test as 2.1. Rotation must still be applied.
- *Verify:* `batch.heicFull_20` ≤ 1,800 ms; `save.inPlace_jpeg` no slower.

**3.4 An 8 GB test mode for the memory rules (M)**
- *Problem (unmeasured):* on an 8 GB Mac today's rules allow, all at once:
  - a 1 GB texture cache (`TextureCache.swift:58-62`)
  - the 200 MB thumbnail cache
  - a RAW develop limited to 512 MB, plus the engine's own buffers
  - several thumbnail workers, each of which may decode a 24 MP PNG at full
    size
- *Cause:* each rule reads the Mac's memory size on its own, so a 16 GB Mac
  cannot test the 8 GB settings.
- *Change:*
  - Read the memory size in one place (`MemoryPolicy.physicalMemory`), which
    accepts `MINIVU_SIMULATE_RAM_GB` in test builds only.
  - Add an 8 GB pass to bench.sh that reports peak memory for flipping
    through photos, grid scrolling, Batch Convert, a RAW develop and a cold
    PNG screenful.
  - If the PNG screenful turns out to be the peak, allow at most 2 large PNG
    or TIFF decodes at once.
- *Expected gain:* turns "8 GB is safe" from a hope into numbers. Product
  changes follow only if the numbers call for them.
- *Effort:* M.

**3.5 Delay and split up the launch-time thumbnail prune (S)**
- *Measured problem:* pruning a tenth of a 5,000-row store takes 386.27 ms,
  as one delete that holds the store's only lock. The real store may hold up
  to 1 GB (`AppServices.swift:12`), so a big prune could hold it longer.
  Meanwhile every thumbnail read and write waits for that lock.
- *Cause:* the prune starts straight away at launch (`AppServices.swift:77`)
  and deletes in one statement (`ThumbnailStore.swift:177`).
- *Change:* start it after the first screenful is drawn, or after 10 seconds
  idle. Delete in batches of about 500 rows, letting go of the lock between
  them.
- *Expected gain:* the first warm screenful at launch never waits behind the
  prune. That wait is inferred, not measured.
- *Verify:* first measure it: a new first-screen benchmark with an
  over-full store. Target within 10% of today's 28.43 ms, with the longest
  lock hold under 30 ms.

**3.6 Precompile the Metal shaders for release builds (S, small gain)**
- *Measured problem:* the first GPU warm-up in a process takes 40.8 ms, then
  1.32 ms. It already runs off the main thread.
- *Cause:* `make_app.sh:124-136` quietly falls back to compiling shaders at
  launch when the Metal toolchain is missing, which it is on this Mac.
- *Change:* installing the toolchain is Harman's decision. Then make
  `make_app.sh` fail for a release package that would fall back. Keep the
  fallback for development builds.
- *Gain:* about 40 ms less background work per launch.
- *Verify:* `launch.gpuWarmUp` first time ≤ 8 ms.

**Measure these before changing anything:**

- **The real app launch.** Never measured. The parts inside the process are
  small (catalog 0.25 ms, store 0.22 ms, bookmarks 2.19 ms). The first browser
  window is 210.1 ms, so profile the window first. Never run this while
  Harman's own copy of minivu is open, because only one copy can run.
- **Compare's main-thread freezes** (44.9 ms for two photos, 63.9 ms for
  four). Take a Time Profiler trace first.
- **The first warm screen's 16.0 ms freeze** in the window. Not profiled.
- **The slideshow video's missing 4 seconds** out of 5,576.55 ms. Add a
  signpost around the wait for the video encoder first.
- **The RAW memory limit on 8 GB Macs.** At 256 MB the develops used less
  memory than at 512 MB (698 against 996 MB for the first file), with renders
  of 366 against 348 ms. That is one run each. Rerun 256, 384 and 512 three
  times each, one file per process.
- **What else stays in memory when flipping photos** (ends at 374 MB). Take
  a memory snapshot at the end.
- **Cold PNG thumbnails** (417.21 ms per decode). Try asking ImageIO to skip
  pixels while decoding (`kCGImageSourceSubsampleFactor`). The gain is not
  known.
- **Getting a photo ready to edit** (110 to 136 ms). It is only felt when
  Crop or Resize opens. The gain is unclear.

### Not worth doing now

The numbers say these are already fast enough, or the gain is too small for
the risk:

- **Next and previous photo:** 7.79 and 9.02 ms. Items 1.6 and 1.8 shave the
  not-yet-loaded case (43.86 ms) as a side effect.
- **The double colour conversion during upload:** 7.1 ms, and only on flips
  to a photo not yet loaded.
- **Loading full-size textures ahead of zoom to 100%:** zoom is 118.64 to
  153.88 ms but shows the screen picture straight away, and keeping full-size
  24 MP textures ready would use too much memory on 8 GB Macs.
- **Lighting and colour sliders:** 6.11 ms per frame.
- **Save:** 102.80 / 113.85 ms, already off the main thread, mostly Apple's
  encoder.
- **AVIF:** Apple's software encoder is 78% of the time and already keeps most
  cores busy. More jobs at once would only add memory (peak
  1,151 MB).
- **More Batch Convert jobs at once in general:** revisit only after 2.1
  lowers memory.
- **Small folders:** 44.42 ms with 11.3 ms on the main thread.
- **Moving catalog, store, bookmark or sidebar work off the main thread:**
  0.22 to 2.46 ms.
- **Batching thumbnail saves, or splitting the store's lock:** a save is
  0.04 ms and nobody waits for the lock (0.00 to 0.01 ms).
- **Warm thumbnails:** 4.09 to 6.26 ms per screenful.
- **Cold JPEG, NEF and video thumbnails:** 135.37 to 231.26 ms, limited by
  Apple's decoders. **Cold HEIC** (1,199.17 ms) already uses the built-in
  thumbnail and quarter-size shortcuts, and is limited by the hardware
  decoder.
- **Copy and move speed itself:** 0.27 ms per file to copy and 0.16 to move,
  almost all in the file system.
- **Running the write queue in parallel:** 20 jobs in 54.71 ms. About 1 ms to
  gain, for real risk.
- **Duplicates, Find by name, the folder walk:** all quick (11.83 to
  536.79 ms).
- **Info panel reads:** under 0.6 ms.
- **Count Colors:** 26.66 ms to count.
- **Caching caption fonts in the slideshow video:** 107.62 ms of 5,576.55,
  about 2%.
- **Pixel size cache:** 40.92 ms for 500 files.
- **Waiting for the graphics chip during upload:** 1 to 2 ms, on a background
  thread.
- **Extra shader pre-warming:** no measured stall.
- **Idle timers:** none found in the code. A five-minute battery check with
  Energy Log is worth doing once, but is not a work item.

### Suggested order

1. Phase 0 (all small).
2. 1.1, 1.2 and 1.3 together, because they share the files benchmarks.
3. 1.5, then 1.4.
4. 1.6, 1.7, 1.8, 1.9.
5. 2.1, then 2.2.
6. 2.3, then 2.4.
7. Phase 3, each after its measuring step.

After each item, rerun its benchmarks with three clean runs and compare them
with today's numbers before moving on.

---

## 5. Keeping it fast

### Budgets to enforce with tests

The free GitHub machines are slow and uneven: CI already stretches every time
limit by 8 (`MINIVU_TEST_SLACK`). Time limits there can only catch disasters.
So the plan uses two kinds of check.

**In CI, check counts and memory, not time.** Counts do not depend on how
busy the machine is. The kit already prints them. Run with the small
built-in test files (`MINIVU_BENCH_QUICK`) and fail the build if:

| check | budget | today |
|---|---|---|
| file opens per viewer flip (not yet loaded) | ≤ 3 | 4.0 |
| header reads in Find, first time | = number of files | 120 for 120 |
| catalog transactions per copied or moved file | = 1 | 1.00 |
| change notices when moving files into the shown folder | ≤ number of files + 2, then single figures after 1.2 | 1,002 for 1,000 |
| file opens per file with filter and rating sort | = 1 after 3.1 | up to 3 (inferred) |
| thumbnail decodes on a warm first screen | = 0 | 0.0 |
| grid scroll peak memory | ≤ 1.3 × today | 281 MB |
| Batch Convert peak memory | ≤ 1.3 × today | 1,057 MB |

**On the reference Mac, check time against a saved baseline.** These are the
targets to hold once the plan is done:

| benchmark | budget | today |
|---|---|---|
| `viewer.next_warm` | median < 16 ms | 7.79 |
| `viewer.open_jpeg` | median < 50 ms | 50 or 59 |
| `edit.slider_lighting` | median < 16 ms | 6.11 |
| `edit.slider_rawExposure` (dragging) | median < 33 ms | 83.73 |
| `edit.cropDragFrame` | p90 < 16 ms | 38.95 |
| `files.rename1000` | main thread < 130 ms, longest freeze < 33 ms | 369.2, 131.7 |
| `files.move1000Shown` | main thread < 30 ms | 200.1 |
| `folder10000.openInWindow` | median < 190 ms | 269.83 |
| `folder1000Photos.ratingSortOpen` | median < 1,200 ms (clean runs) | 2,848 to 3,498 |
| `batch.jpeg2048_20` | median < 800 ms, peak < 600 MB | 1,506.24, 1,057 |
| any window benchmark | longest main-thread freeze < 50 ms | 131.7 (rename) |

### The benchmark routine

1. **Save a baseline.** After phase 0, run the full `scripts/bench.sh` on the
   reference Mac (the M4 with 16 GB), with clean runs only, and commit the
   results file as the baseline.
2. **Compare before merging.** Move `compare.py` into `scripts/`, and add
   `scripts/bench.sh --compare baseline`. It flags any clean median more than
   15% slower than the baseline. Run it before merging any branch that
   touches decoding, the browser, the viewer, editing or Batch Convert.
3. **Update the baseline on purpose.** When a change makes something faster,
   rerun and commit the new baseline in the same pull request, so the next
   slowdown is measured from the new level.
4. **Test the test.** Check once that the routine works: add a 10 ms sleep to
   decoding and see the comparison flag it. Add an extra header read and see
   the CI count test fail.
5. **Keep the machine quiet.** Never run benchmarks while something else is
   building. bench.sh's gate (phase 0.4) waits for that, but it is still
   worth closing other work.
6. **Fix the docs when numbers change.** The wiki's 186 MB grid-scroll figure
   is out of date. Update it once 1.9 has been measured.
