# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Heardy is a Flutter (Android-only) app that downloads music from YouTube/YouTube Music/Spotify and plays it back fully offline. There is no backend — everything (audio files, thumbnails, lyrics, metadata) lives on-device in SQLite + the filesystem. README.md (in Spanish) has the full feature list and dependency rationale.

## Commands

```bash
flutter pub get                  # install dependencies
flutter run                      # run on connected device/emulator (Android only, no iOS config)
flutter build apk                # release APK
flutter analyze                  # static analysis (flutter_lints)
flutter test                     # run tests (no test/ directory exists yet)
flutter clean                    # wipe build/ and .dart_tool/ — use if you hit stale-build/plugin-registration issues
```

There is no CI config and no `analysis_options.yaml` beyond the `flutter_lints` default. Signing config for release builds lives in `android/keystore.properties` (gitignored) and `heardy-release-key.jks`.

## Architecture

### Directory map

```
lib/
├── main.dart                        # entrypoint: DB init, notifications, AudioService init, permission
│                                     # requests, Provider tree wiring, RouteGenerator (only "/" and "/playlist")
├── models/                          # plain data classes, hand-rolled toMap/fromMap/toJson/fromJson
│   ├── song.dart                    # a downloaded track: id, title, artist, duration, filePath, artPath,
│   │                                # format, downloadDate
│   ├── playlist.dart                # id, name, creationDate, sortOrder, optional originalUrl
│   └── playlist_song.dart           # mirrors the playlist_songs join table; mostly unused directly since
│                                     # DatabaseHelper queries the join table with raw SQL instead
├── providers/                       # ChangeNotifier state holders (see "State management" below)
│   ├── music_provider.dart          # playlists + current playlist songs + cold-start playback restoration
│   ├── download_provider.dart       # the download queue, YouTube/Spotify orchestration, download UI state
│   ├── settings_provider.dart       # theme preset + max search results (SharedPreferences-backed)
│   └── error_provider.dart          # rolling in-memory error log — defined but NOT wired into the app
├── services/                        # business logic, no Flutter widget dependencies
│   ├── database_helper.dart         # SQLite schema, migrations, all CRUD/queries — single source of truth
│   ├── youtube_service.dart         # the actual YouTube extraction/download engine: metadata fetch, stream
│   │                                # manifest resolution, chunked HTTP download, retry/backoff, playlist
│   │                                # scraping fallback, and the shared download circuit breaker.
│   ├── ytmusic_service.dart         # wraps dart_ytmusic_api as the primary metadata/search/playlist path,
│   │                                # falls back to youtube_service.dart on failure. Delegates ALL actual
│   │                                # downloading straight to YoutubeService (YTMusic API can't download)
│   ├── spotify_service.dart         # scrapes open.spotify.com/embed/* for metadata (no official API);
│   │                                # audio itself still comes from YouTube via YoutubeService.searchAndDownload
│   ├── audio_player_handler.dart    # audio_service/just_audio bridge: queue, background playback, lock-screen
│   │                                # controls, play-history recording, playback-state persistence
│   ├── playback_state_service.dart  # SharedPreferences read/write for "resume where I left off"
│   ├── lyrics_service.dart          # fetches/caches synced .lrc lyrics from LRCLIB
│   ├── repair_service.dart          # manual "fix a broken player/library" flow, triggered from Settings
│   ├── audio_analysis_service.dart  # waveform amplitude extraction for the now-playing seek bar
│   └── log_service.dart             # appends download errors to a plain-text log, viewable from Settings
├── screens/                         # one file per screen/tab, StatefulWidget + Provider consumers directly
│   ├── main_shell_screen.dart       # bottom-nav shell (Home/AddFromYouTube/Search/Settings) + MiniPlayer
│   ├── home_screen.dart             # playlist library: create/rename/reorder/delete
│   ├── add_from_youtube_screen.dart # "analyze link" flow for YouTube/Spotify URLs → enqueues via DownloadProvider
│   ├── search_screen.dart           # YouTube/YTMusic search UI
│   ├── playlist_detail_screen.dart  # song list for one playlist: search/sort/reorder/delete/play
│   ├── now_playing_screen.dart      # full player UI — largest screen by far
│   └── settings_screen.dart         # theme picker, max search results, error log viewer, manual repair trigger
├── widgets/                         # glass_card, mini_player, song_tile, download_progress_card
└── theme/app_theme.dart             # navy/violet/rose presets + gradient scaffold decoration
```

### State management: Provider, three top-level providers wired in `main.dart`

- `MusicProvider` — owns the list of playlists and the songs of the currently-viewed playlist (queried fresh from SQLite via `DatabaseHelper` on every mutation, not cached/derived). Also owns playback-state restoration on cold start (see below).
- `DownloadProvider` — owns the download queue and all download/search orchestration (YouTube + Spotify). Wired as a `ChangeNotifierProxyProvider2` so it always has live references to `MusicProvider` and `AudioPlayerHandler`, because a completed download needs to update both the playlist list and (if that playlist is currently loaded in the player) the live queue.
- `SettingsProvider` — theme preset + max search results, persisted to `SharedPreferences`.

`AudioPlayerHandler` (the `audio_service`/`just_audio` handler) is provided directly via `Provider<AudioPlayerHandler>.value`, not a `ChangeNotifier` — screens read it via `context.read`/`context.watch` and react to its `mediaItem`/`playbackState`/`queue` streams directly.

### Data layer: `DatabaseHelper` (SQLite via sqflite), single source of truth

Tables: `songs`, `playlists`, `playlist_songs` (join table, `ON DELETE CASCADE` both ways, ordered by `orderIndex`), `download_queue` (persists across app restarts/crashes — supports both YouTube and Spotify-sourced items via a `source` column), `play_history` (for the stats screen — top songs/artists this week/month).

Schema changes go through `_onUpgrade` with sequential `if (oldVersion < N)` blocks — bump `version` in `_initDB` and add a new block, never rewrite an existing one. Foreign keys require `PRAGMA foreign_keys = ON` (set in `_onConfigure`), which is how cascade deletes work.

Songs are content-addressed by `id`: a YouTube video ID, or a synthesized `spotify_<sanitized>` / Spotify track ID for Spotify-sourced tracks. A song can belong to multiple playlists via `playlist_songs`; `MusicProvider`/`DatabaseHelper` methods that remove/delete a song always check `getPlaylistCountForSong` first and only delete the underlying file + row when it's not referenced by any other playlist (see `deletePlaylist`, `removeSongFromPlaylist`).

**Note:** `addToDownloadQueue` dedupes on `(videoId, playlistId)`, not `videoId` alone (database_helper.dart:434-440) — see Known issues #5.

### Download pipeline (`DownloadProvider` + `YTMusicService`/`YoutubeService`/`SpotifyService`)

Downloads are never awaited directly by the UI — everything funnels through a **persistent SQLite-backed queue** (`download_queue` table) so an in-progress batch survives app kill/restart:

1. `downloadVideo` / `downloadPlaylist` / `downloadSpotifyTrack` / `downloadSpotifyCollection` resolve metadata, dedupe (already-in-playlist / already-downloaded-elsewhere), then `INSERT` into `download_queue` and call `processQueue()`.
2. `processQueue()` is a self-scheduling loop guarded by `_isProcessingQueue` — it pulls up to `_maxConcurrentDownloads` items at a time and fires `_processQueueItem` per item without awaiting it, preserving playlist order via `expectedOrderIndex`. **`_maxConcurrentDownloads` is now `1`** (it was 3; see Known issues): YouTube's bot detection reacts to request *volume*, and measurement showed 24/24 sequential requests succeeding where multi-client bursts failed constantly. Chunk-level parallelism *within* a single download still provides the throughput.
3. Each item retries up to 2 attempts with a 10-minute budget and exponential backoff before being dropped from the queue and surfaced as a friendly error (rate-limit / timeout detection in `_friendlyDownloadError`).
4. `cancelAllDownloads()` / `prepareForNewDownloads()` bump `_downloadSessionId` — in-flight downloads check this against their captured session id to bail out cleanly instead of using cancellation tokens.

`YTMusicService` wraps `dart_ytmusic_api` as the primary source and **falls back to `YoutubeService`/`youtube_explode_dart`** on failure for every operation (metadata, playlist expansion, search) — YouTube's InnerTube API is less prone to blocking but less complete, so both paths exist for resilience. `YoutubeService` itself has multiple layers of resilience: cycling `YoutubeApiClient` configs (android/androidVr), retry-with-backoff on transient errors, a short-lived metadata cache to avoid re-hitting YouTube when the same video is analyzed twice in the "add from YouTube" flow, and a **shared static circuit breaker** (`_blockedUntil`/`_consecutiveBlocks`/`circuitBreakerEnabled`) that pauses every concurrent caller together when YouTube signals a hard block (403/401/VideoUnavailableException), instead of each of the 3 concurrent download workers retrying independently and re-triggering the block in lockstep. `SpotifyService` has no official API use — it scrapes `open.spotify.com/embed/*` server-rendered `__NEXT_DATA__` JSON, then downloads the matching audio from YouTube (search-and-match by title/artist/duration).

### Playback (`AudioPlayerHandler` extends `BaseAudioHandler` + `just_audio`)

Bridges `just_audio`'s `AudioPlayer` to `audio_service`'s `PlaybackState`/`MediaItem`/queue streams for background playback + lock-screen/notification controls. Key details:

- The queue is backed by a `ConcatenatingAudioSource`; each `MediaItem.extras['filePath']` is the on-disk audio file — items are always filtered against `File(path).existsSync()` before being added to the source, so a missing/deleted file is silently skipped rather than crashing playback.
- Play-history recording (`play_history` table) happens via `_startTracking`/`_finalizePlay`, which watches position updates and only records a play once >= 50% of the track's duration has been reached (see `_finalizePlay`), triggered on track change or track completion.
- Playback state (queue, current media id, position, shuffle/loop, speed) is persisted to `SharedPreferences` on every `playbackEventStream` tick via `PlaybackStateService`, and restored once on cold start — `main.dart` waits 800ms after `runApp` before calling `MusicProvider.restorePlaybackState`, which reloads playlists/songs from SQLite, rebuilds `MediaItem`s (re-attaching `filePath`/`artPath` extras, since those aren't persisted, only IDs are), and calls either `playPlaylist` (was playing) or `restorePlaylist` (was paused, loads the source without auto-playing).

### Lyrics (`LyricsService`)

Fetches synced `.lrc` lyrics from LRCLIB (a public, keyless API) and caches them to `<app documents>/lyrics/<songId>.lrc`, so lookups are 100% offline after the first fetch. Lyrics are pre-fetched in the background at the end of every download (see `_downloadVideoDirectly`/`_downloadSpotifyDirectly` in `DownloadProvider`) so they're typically already cached by the time the user opens "now playing".

### Error handling & diagnostics

`LogService` appends download errors to `<app documents>/download_errors.log`; Settings has a screen to view/clear this log. `RepairService.performFullRepair` (triggered manually from Settings) is a last-resort recovery path: scans for corrupted/orphaned audio files, cleans temp files, checks DB consistency, and fully resets `AudioPlayerHandler` + `MusicProvider` state. `ErrorProvider` (`providers/error_provider.dart`) is a rolling in-memory error log but is **not currently wired into the provider tree or read by any screen** — treat it as dead/scaffolded code, not active architecture. Most services/providers also just `print()` liberally for on-device `flutter run` debugging — this is intentional throughout the codebase, not something to clean up incidentally.

### UI structure

`MainShellScreen` hosts 4 bottom-nav tabs over an `IndexedStack`: Home (playlist library), `AddFromYouTubeScreen` embedded in-shell (labeled "Descargas" — analyze/download a YouTube or Spotify link), Search, and Settings — with a persistent `MiniPlayer` overlaid above the nav bar. `PlaylistDetailScreen` and `NowPlayingScreen` are pushed routes. Routing is a manual `onGenerateRoute` switch in `main.dart` (`RouteGenerator`) — only `/` and `/playlist` (expects a playlist id `String` argument) are registered. `NowPlayingScreen` is the largest screen by far (dynamic background derived from cover art via `palette_generator`, synced lyrics view, reorderable "up next" queue, waveform seek bar backed by `AudioAnalysisService`). `AppTheme` supports three presets (navy/violet/rose) applied globally through `SettingsProvider`.

### Android specifics

Background playback relies on `audio_service` + `flutter_background_service` + `wakelock_plus` (held during active downloads, see `WakelockPlus.enable()/disable()` bracketing in `DownloadProvider`) + a foreground notification channel (`com.heardy.app.audio`) for the persistent playback notification. Downloads show progress via a separate channel (`com.heardy.app.downloads`). `min_sdk_android: 21` per `flutter_launcher_icons` config in `pubspec.yaml`.

## Known issues

### Intermittent `VideoUnavailableException` / HTTP 403 in the download queue (retry storm — fix applied)

**Where the logic lives:**
- `lib/providers/download_provider.dart` — `processQueue()` and `_processQueueItem()`: the concurrency gate and the *outer* retry layer.
- `lib/services/youtube_service.dart` — `_isRetryableError()`, `_isHardBlockError()`, `_getVideoWithFallback()`, `getVideoInfo()`, `downloadVideoWithAudio()`: the retry layers, the shared circuit breaker, and the classification of what counts as retryable vs. a hard block.

**Root cause (confirmed from code, not theory):**

1. **Three retry layers were stacked on top of each other, uncoordinated.** Outer (`_processQueueItem`: 2 attempts, 3s/6s backoff, 10-min budget each) → middle (`downloadVideoWithAudio`: 5 attempts, 5s/10s/15s/20s backoff) → inner (`_getVideoWithFallback` used to retry 3 more times internally, 1s/2s backoff). A single logical download could fire up to 2×5×3 = 30 real requests before giving up, with no shared budget across layers or across sibling downloads.
2. **`_isRetryableError` treats almost everything as retryable**, explicitly including `VideoUnavailableException` and HTTP 403/401 — no distinction between "transient hiccup" and "YouTube is actively blocking this session."
3. **`_maxConcurrentDownloads = 3`** means up to 3 of these nested retry loops ran truly concurrently, dispatched ~800ms apart, so their backoff timers stayed roughly in phase — when request volume triggered a soft block, all 3 workers backed off and retried near-simultaneously, re-triggering the block (a retry storm, not a classic shared-memory race).
4. **The feature meant to prevent this was dead code:** `_useCooldown`/`useCooldown`/`setCooldown()` were never read by `processQueue`, `_processQueueItem`, or anything in `youtube_service.dart`, and `setCooldown` wasn't called from any screen. The README advertises cooldown support; the toggle had no effect on real behavior.
5. **Separate bug, same area (fixed):** `addToDownloadQueue` dedupes on `(videoId, playlistId)` not `videoId` alone — the same video queued via two playlists could run as two concurrent `_activeDownloads`, both writing to the identical file path `<musicDir>/<videoId>.<ext>` via a truncating `openWrite()`, corrupting the file. Fixed with a separate in-memory lock, `DownloadProvider._activeVideoIds`: `processQueue()` won't dispatch a second queue item for a `videoId` that's already active, and `_processQueueItem` re-checks for an existing, fully-downloaded song right after acquiring the lock — if a sibling item for the same video finished while this one was waiting, it just links the existing file to the new playlist instead of re-downloading.

**Fix applied:**
- Collapsed the redundant inner retry layer: `_getVideoWithFallback` now makes a single attempt; only the outer per-method loops (`getVideoInfo`, `downloadVideoWithAudio`) retry. Worst case per download dropped from ~30 requests to ~5-10.
- Added a **shared static circuit breaker** in `YoutubeService` (`_blockedUntil`, `_consecutiveBlocks`, `circuitBreakerEnabled`): when any call path hits a hard-block error, it sets a shared cooldown window with escalating duration (20s → 40s → 80s… capped at 180s) that **every concurrent worker waits out before firing its next request** (`_respectGlobalCooldown`, called at the top of every retry attempt in `getVideoInfo`, `downloadVideoWithAudio`, `getPlaylistVideoIds`, `searchVideos`, and inside `_getVideoWithFallback`). This replaces 3 independent, roughly-synchronized backoffs with one coordinated pause.
- Added ±0-30% jitter to every fixed backoff delay (`_withJitter`) so residual per-worker retries desync instead of retrying in lockstep, including `DownloadProvider._processQueueItem`'s own 3s/6s backoff.
- `DownloadProvider.setCooldown()` now actually does something: it toggles `YoutubeService.circuitBreakerEnabled`, so the existing (previously dead) UI setting controls whether the circuit breaker is active.

**Symptom observed after shipping the above:** ~6 minutes stuck on "Obteniendo información del video..." after submitting a playlist. Initial hypothesis was that `_isHardBlockError` matching `VideoUnavailableException` let a single genuinely-dead video (deleted/private/region-locked) freeze the whole shared cooldown — so that classification was removed. **This hypothesis was wrong and reverted**: the user confirmed the "unavailable" videos were 100% real and playable normally. Root cause, confirmed by reading the vendored `youtube_explode_dart-3.1.0` source: `WatchPage.isVideoAvailable` (`lib/src/reverse_engineering/pages/watch_page.dart:54`) determines availability by checking for a `<meta property="og:url">` tag in the scraped watch-page HTML — nothing more. Under concurrent load (3 workers scraping watch pages at once), YouTube serving a bot-check/consent page or a differently-shaped response for that request is enough to make the tag disappear, and the library incorrectly throws `VideoUnavailableException` for a perfectly fine video. In this app's real usage, `VideoUnavailableException` is therefore usually a *mislabeled session-wide block*, not a per-video permanent condition, and needs the same shared cooldown as 403/401 to actually recover. `_isHardBlockError` now includes it again (with this evidence recorded in its doc comment). The part of the original fix that *did* matter — `_recordBlock()` skipping escalation while already inside an active cooldown window, so 3 concurrent workers hitting the same incident don't each independently bump `_consecutiveBlocks` to the longest tier — stays in place and is what actually prevents the freeze from compounding.

**Actual root-cause fix (from a real `download_errors.log` sample):** two real, playable videos were failing with `VideoUnavailableException: Video '<id>' is unavailable` after exhausting all 5 inner attempts. Reproduced directly: fetching `https://www.youtube.com/watch?v=<id>` from this environment returned HTTP 200 but the body was a "Sign in to confirm you're not a bot" / reCAPTCHA page with no `<meta property="og:url">` tag — exactly what `WatchPage.isVideoAvailable` checks for — while calling `dart_ytmusic_api`'s `getSong(videoId)` for the *same* two IDs, from the *same* environment, succeeded immediately and returned correct title/artist/duration. Architecturally, `YoutubeService`'s `videos.get()` (via `VideoClient._getVideoFromWatchPage`) has no alternative to this HTML scrape — unlike `streamsClient.getManifest()`, it doesn't accept a `ytClients` parameter, so it can never route around the bot-check page the way stream-manifest fetching can. `dart_ytmusic_api`, by contrast, calls YouTube's structured InnerTube `player` JSON endpoint (`music.youtube.com/youtubei/.../player`) and isn't gated by the same wall.
- **Fix:** `YTMusicService.downloadVideoWithAudio` now calls `_ytmusic!.getSong(videoId)` first and, on success, primes `YoutubeService`'s metadata cache via the new `YoutubeService.primeMetadataCache(...)` (both `downloadVideoWithAudio` and `getVideoInfo` already check this cache before calling the fragile `_getVideoWithFallback`/`videos.get()`). On any failure it silently falls through to the previous behavior unchanged. This means the download path now uses the same InnerTube-based metadata source the "Analizar enlace"/search preview flow already relied on, and skips the watch-page scrape entirely whenever it succeeds.
- ~~The stream/audio download step (`_getManifestWithFallback` → `streamsClient.getManifest`) is unaffected by this fix and still uses the client-fallback cascade — it wasn't implicated in this specific failure.~~ **This is now known to be wrong — see "Where the block actually lands" below.** It was true only in the sense that the log sample at the time showed metadata failing first; once metadata was fixed, the failures moved wholesale to the manifest step.

### Testing downloads from desktop (no device install needed)

```bash
flutter test test/download_smoke_test.dart
```

This exercises the **real** download engine against YouTube — metadata, manifest, chunked download, validation, thumbnail — and was what localized the bug below. It exists because these failures only showed up on-device, and checking them meant rebuilding and reinstalling the APK every time.

Why it works: `dart run` can't load Flutter plugins, but `YoutubeService`'s *only* plugin dependency is `path_provider`, so substituting `PathProviderPlatform` with a temp directory is enough. `flutter test` runs on the Dart VM with real networking. `DownloadProvider` is deliberately **not** covered — that would drag in sqflite, wakelock and notifications; the engine is where the bugs are.

Two things to know before trusting a red run:

- **A download failure is usually not a code bug.** The suite detects YouTube's bot wall (`_isBotWall`) and reports it as an environmental condition instead of failing, because it is intermittent by design (see below). Any *other* exception does fail the test.
- **A bot-walled download takes ~10 minutes to conclude**, not seconds: 5 attempts with the circuit breaker's escalating cooldowns (measured: attempts at 22s, 64s, 148s, 310s). The per-test timeout is 12 minutes for that reason. A healthy download takes ~1s.
- Tests share `YoutubeService`'s **static** circuit-breaker state, so `setUp` calls `YoutubeService.resetCircuitBreaker()` — without it, one blocked test leaves the next ones waiting out inherited cooldowns and failing for the wrong reason.

Also note: writing this test against `YoutubeService` directly is a trap that produced a false bug report during development. `DownloadProvider` uses **`YTMusicService`**, whose InnerTube metadata priming is exactly what avoids the fragile `/watch` scrape. Test the same class the app uses.

### Where the block actually lands: the manifest step, and the breaker was blind to it

Measured with `test/download_smoke_test.dart`, `tool/client_sweep_probe.dart` and repeated multi-video sweeps:

1. **The metadata step is fixed.** InnerTube priming works — the A/B in the smoke test regularly shows the `/watch` scrape failing on a video while InnerTube returns correct metadata for it in the same run.
2. **The failures moved to `streamsClient.getManifest`**, which throws `VideoUnplayableException: ... Reason: Sign in to confirm you're not a bot`.
3. **`_isHardBlockError` did not match `VideoUnplayableException`** — so the shared circuit breaker *never engaged for the failure mode that actually happens*. The error was still classified retryable, but only **by accident**: `_isRetryableError` matches `'stream'`, which happens to appear in the message's "Streams are not available for this video." So a download burned its 5 attempts on short fixed backoffs without ever triggering the shared cooldown, keeping the session blocked and failing every subsequent song in the queue. **Fixed** by adding `videounplayableexception` plus the literal `confirm you're not a bot` marker (both ASCII and typographic apostrophe — YouTube sends `’`).

**The block is session-wide and volume-driven, not per-video.** This matters because the opposite conclusion is very tempting from a single run. Two back-to-back sweeps of the same 10 well-known videos gave *opposite* results for the same IDs (a-ha succeeded in run 1 and failed in run 2; Nirvana the reverse), with ~80% failures in both. Roughly ten sequential manifest requests are enough to trip the wall. And `tool/client_sweep_probe.dart` shows **all 11** InnerTube clients the library exposes failing together once the session is blocked — so no client is immune, and expanding the cascade only adds request volume. (It also falsified the older note claiming `androidVr` fails 100% of the time: it serves bytes fine, as do `android`, `androidSdkless` and `ios`. That 6/6 measurement was of a blocked session, not of the client.)

**Open tension, not yet resolved:** with the breaker now correctly engaging on manifest blocks, a blocked session makes a large playlist stall for a long time by design — the breaker is protecting YouTube's rate limit, but from the user's side "downloads stopped". Reducing request volume further (deliberate spacing between queue items, on top of `_maxConcurrentDownloads = 1`) is the untried lever; nothing currently paces successive downloads.

**Follow-up bug: cancel + immediately resubmitting the same link still looked stuck.** Confirmed via `download_errors.log` that the user explicitly pressed cancel, then resubmitted the same playlist link, and it hung again. Root cause: `_respectGlobalCooldown` (and the retry backoff delays in `downloadVideoWithAudio`, and `DownloadProvider._processQueueItem`'s own outer backoff) all used a single uninterruptible `Future.delayed(...)` — a worker cancelled mid-sleep (e.g. partway through a 180s circuit-breaker cooldown) kept sleeping for the *entire* remaining duration before ever checking `isCancelled`/`_cancelRequested`/session-id again. Meanwhile that worker still held its `videoId` in `DownloadProvider._activeVideoIds` (the lock added for the earlier file-path-collision fix) and its `queueId` in `_activeDownloads`, both only released in its `finally` block once the sleep actually ended. So resubmitting the *same* video right after cancelling queued a fresh item that `processQueue()` correctly refused to dispatch (per that same lock) until the stale, cancelled-but-still-sleeping worker finally woke up on its own — up to 180s later, which read as "still stuck."
- **Fix:** added `YoutubeService._cancellableDelay(duration, isCancelled)`, which polls `isCancelled` every 300ms instead of sleeping the full duration in one shot. `_respectGlobalCooldown`, `_getVideoWithFallback`, and `downloadVideoWithAudio`'s retry backoff now all use it (threaded through the existing `isCancelled` callback parameter that was already being passed down for chunk-download cancellation). `downloadVideoWithAudio`'s retry loop also now checks `isCancelled` at the very top of every attempt, before even entering the cooldown wait. `DownloadProvider._processQueueItem`'s own 3s/6s outer backoff got the same treatment (checks `sessionId`/`_cancelRequested` every 300ms). Also fixed `DownloadProvider.cancelAllDownloads()`, which set `_cancelRequested = true` but — unlike `prepareForNewDownloads()` — never set it back to `false` and never waited for active workers to actually wind down; it now does both (with a short 3s grace window, since workers should unblock almost immediately with the above fix in place).
- Note: `getVideoInfo` and `searchVideos` (the "Analizar enlace"/search preview paths, not the download-queue path) still use a plain, non-cancellable sleep for their own cooldown/backoff waits — they have no `isCancelled` concept today since nothing currently lets the user cancel an in-flight preview/search. Not fixed since it wasn't implicated in the reported symptom; would need the same treatment if that ever changes. (`getPlaylistVideoIds` *is* now cancellable — see below, it turned out to be in the download path.)

### Silent infinite hangs: neither HTTP library sets a timeout (fixed)

**The pattern, and why it kept resurfacing:** *none* of the three network layers this app depends on has a default timeout, so every call site has to impose its own or it can wait forever. A hung socket doesn't throw, so nothing lands in `download_errors.log` and the UI just sits on whatever status message it last set. This was diagnosed and fixed piecemeal (first `youtube_explode_dart`, then the rest), so when auditing a *new* network call here, assume no timeout exists until you've added one.

- **`youtube_explode_dart`** — `YoutubeHttpClient` defines none. Covered by `YoutubeService._withTimeout` with `_requestTimeout` (30s), `_manifestTimeout` (45s, higher because `_parseStreamInfo` fires a HEAD per stream), and `_playlistPageTimeout` (30s).
- **`dart_ytmusic_api` 1.3.7** — has literally zero timeout handling anywhere in its `lib/`. Covered by `YTMusicService._withTimeout` / `_apiTimeout` (20s) on all four call sites: `initialize()`, `getSong`, `getPlaylistVideos`, `searchSongs`.
- **`dart:io` `HttpClient`** — `connectionTimeout` only bounds *establishing* the connection, **not** reading the response. `request.close()` and body reads (`transform(utf8.decoder).join()`, `drain()`) on an already-open socket wait forever. Applies to `YoutubeService._customScrapePlaylist` and all three `SpotifyService` call sites, which all set `connectionTimeout` and were nonetheless hangable.

**The two that were genuinely in the download path** (the rest only froze a preview):

1. **`YTMusicService.downloadVideoWithAudio`'s metadata priming** (`_ytmusic!.getSong`) runs *inside* the download. Its `try/catch` was no protection — a future that never completes never throws. The only backstop was `_processQueueItem`'s 10-minute `attemptBudget`, twice: **20 minutes of an apparently frozen download.** Because `YTMusicService` is the *primary* path for every operation, its hangs always preempted `YoutubeService`'s existing timeouts.
2. **Playlist expansion** (`getPlaylistVideoIds`) is called by `DownloadProvider.downloadPlaylist` *before* a single row exists in `download_queue` — so neither `attemptBudget` nor `cancelAllDownloads()` could reach it, and it had no timeout of its own at either of its two stages: `_customScrapePlaylist` (tried first; unbounded body read plus up to 50 unbounded continuation POSTs) and the `await for` over `yt.playlists.getVideos(...)`, which paginates internally. Fixed with a per-event `.timeout(_playlistPageTimeout)` on the stream — bounding the *gap between pages*, not the total, so large playlists still work — and by threading `isCancelled` (the same `_cancelRequested`/session-id staleness check the queue workers use) all the way down through `YTMusicService.getPlaylistVideoIds` into both stages.

**Cancellation had to be un-swallowed to thread it through.** `_customScrapePlaylist`'s `catch` returns its partially-filled `videoIds`, and `getPlaylistVideoIds`'s first `catch` falls through to the `youtube_explode_dart` attempt — so a cancellation would have been laundered into "expansion succeeded with a partial list" (queueing only the tracks resolved so far) or "the scraper failed, try the other path". Both now `rethrow` when `isCancellationError(e)`, and `DownloadProvider.downloadPlaylist`'s `catch` treats cancellation as not-an-error so it stops overwriting the `"Descargas canceladas."` message with `"Error descargando la lista"`.

**Second pass — three more, found by auditing what the first pass didn't cover:**

- **`searchAndDownload` bypassed all three protections** (timeout, shared circuit breaker, cancellation check) despite being the first step of *every* Spotify download. It doesn't reuse `searchVideos` — it calls `yt.search.search(query)` directly because it needs the raw `Video` objects to duration-match — so it silently missed everything `searchVideos` had. Unbounded search plus no cooldown respect meant it also fired requests exactly when YouTube was already blocking, feeding the block the breaker exists to stop.
- **Infinite loop in the chunked downloader.** `_downloadSequential`'s `while (received < totalBytes)` only advances if `received` grows, and nothing guaranteed it: a `206` with an **empty body** makes the inner `await for` finish without emitting a chunk, leaving `received` untouched and the loop reissuing the identical `Range` request forever. No timeout catches this — each individual request succeeds quickly. The download sits frozen at the same percentage burning network and battery indefinitely. Now each iteration compares `received` against its value at entry and throws if it didn't move (message contains "chunk" so `_isRetryableError` treats it as retryable and the outer loop retries properly).
- **`_isAnalyzing` had no `finally`.** `add_from_youtube_screen._analyzeUrl` reset it at each of its five exits (four success paths + the `catch`), so it worked only by coincidence — and that flag is what disables the text field and the "Analizar" button, so leaving it `true` bricks the screen until app restart. Adding `if (!mounted) return` guards (needed because every `setState` ran after an `await`) would itself have introduced exactly that leak. Now it resets in one `finally`.

**The interactive-vs-background distinction in the circuit breaker.** The shared cooldown escalates to 180s, which is right for a background batch but turned the preview paths into a dead screen for three minutes with no text and no way out — indistinguishable from a hang, since those paths disable their own UI while waiting. `_respectGlobalCooldown` now takes an optional `maxWait`: when the remaining cooldown exceeds it, it **throws instead of waiting** (`_interactiveCooldownCap`, 8s) with a message saying how long is left. Callers pass it *outside* their retry loop so it propagates rather than becoming another retry. `getVideoInfo` and `searchVideos` hardcode the cap — they have no background callers today (the download path uses `downloadVideoWithAudio` / `searchAndDownload`), and their doc comments say to parameterize if that changes. `getPlaylistVideoIds` has *both* kinds of caller, so it takes `interactive: bool` (threaded through `YTMusicService`): `true` from the analyze preview, default `false` from `downloadPlaylist`.

**Two adjacent bugs found in the same audit:**
- `YTMusicService.initialize()` assigned `_ytmusic = YTMusic()` *before* `await initialize()`, so a failed init left the field non-null but unusable — and since the guard is `if (_ytmusic == null)`, nothing ever retried it. The instance stayed permanently broken for the life of the process, silently degrading every operation to the fallback. Now the field is only assigned once init completes.
- `SpotifyService.resolveShortLink` recursed on the `location` header with no depth limit — a redirect cycle meant unbounded recursion, each level making a real network request. Capped at `_maxRedirects` (5).

### The JS challenge solver is a dead end for this app (investigated, closed)

youtube_explode_dart 3.1.0 ships an EJS solver for YouTube's `n`/`sig` JS challenges (`lib/src/reverse_engineering/challenges/ejs/`), but only a `DenoEJSSolver` implementation — and Deno doesn't exist on Android. The obvious next step looked like implementing `BaseEJSSolver` on top of a QuickJS binding (`flutter_js`) to get it working on-device. **Don't. It would be dead weight.** Two independent reasons, both measured (`tool/` holds the probes):

1. **The solver is never invoked under this app's configuration.** `StreamClient._parseStreamInfo` gates the entire bulk-solve block behind **`watchPage != null`** (`stream_client.dart:252`), and every `getManifest` call here passes `requireWatchPage: false` specifically to avoid the bot-walled `/watch` scrape. The two are mutually exclusive: enabling the solver means re-enabling the exact scrape whose `TransientFailureException('Video watch page is broken.')` was the original bug. (Note the gate is *only* about `watchPage` being non-null — `solveBulk` itself needs nothing from the page but `sourceUrl`, the player `base.js` URL, which `tool/solver_probe.dart` fetches straight from `youtube.com/iframe_api` without touching `/watch`. So the coupling is yed's, not YouTube's — routing around it would mean forking the library.)
2. **There is nothing to solve.** `tool/manifest_probe.dart` fetches a manifest exactly as the app does (android / androidSdkless, `requireWatchPage: false`) and dumps the challenge-relevant query params plus real throughput. Result, reproducible across runs: **no `n` parameter on any audio stream** (so no throttling parameter to descramble) and **no `s=`** (unciphered signature) — the URLs arrive with `sig=` already applied and work as-is. Measured throughput on itag 140: **15–21 MB/s**. An unsolved `n` throttles to ~50–80 KB/s, so this is conclusive: the android clients return ready-to-use, unthrottled URLs, which is the entire reason those clients exist.

`tool/solver_probe.dart` is kept because it *does* prove the solver works given a JS runtime (all three `n` challenges transformed; ~2s cold via Node, ~0.6s with the preprocessed player cached). If YouTube ever starts returning `n` or `s=` on the android-client streams, that probe plus this note is the starting point — re-run `manifest_probe.dart` first to confirm the premise changed before writing any solver code.

## Conventions

- **State management: Provider only.** No Riverpod, Bloc, GetX, or Redux in `pubspec.yaml` — every stateful piece of app state is a `ChangeNotifier` subclass registered in `main.dart`'s `MultiProvider`, consumed via `Provider.of`/`context.watch`/`context.read`. Screens hold their own local UI state (search text, sort mode, etc.) directly in `State` objects rather than lifting it into a provider.
- **File naming:** snake_case file names matching one primary PascalCase class per file (e.g. `music_provider.dart` → `MusicProvider`, `song_tile.dart` → `SongTile`). Private helpers/fields are `_camelCase`.
- **Two service-instantiation styles coexist:** singleton-via-static-instance (`DatabaseHelper.instance`, `LyricsService.instance`) vs. plain instantiated-per-owner classes with only static/instance methods (`RepairService` is all-static; `YoutubeService`/`YTMusicService`/`SpotifyService` are instantiated once per owning provider/screen and reused). `YoutubeService`'s circuit-breaker state is `static` regardless of instance count — a precedent already set by `_metadataCache`.
- **Models are hand-rolled, uniformly:** every model in `models/` implements the same `toMap()`/`fromMap(Map)`/`toJson()`/`fromJson(String)` quartet by hand — no `json_serializable`/`freezed`/`equatable`. Match this shape for any new persisted entity.
- **Fallback-chain pattern for external data:** `YTMusicService` wraps every method in the same try-primary-API/catch-log/fallback-to-`YoutubeService` shape. Follow this same shape for new YTMusic-backed operations rather than calling `dart_ytmusic_api` directly from UI code.
- **`MediaItem` construction is duplicated, not factored out:** the same `MediaItem(id:..., album:..., title:..., artist:..., duration:..., artUri:..., extras: {'filePath':..., 'artPath':..., ...})` literal is repeated near-verbatim across `MusicProvider` (3 places) and `DownloadProvider` (4 places) instead of a shared helper. Match the existing extras keys (`filePath`, `artPath`, `playlist_id`) exactly — `AudioPlayerHandler` reads them by string key.
- **Error handling is print-and-swallow by default:** most `catch (e)` blocks in `services/`/`providers/` `print()` and return a default/continue rather than rethrow — intentional for a single-user offline app with no crash reporting. `LogService.logError` and the download path's `rethrow`s are the deliberate exceptions.
- **Spanish throughout:** UI strings, most inline comments, and many `print()` messages are in Spanish; some service-level comments/logs (especially `youtube_service.dart`, `ytmusic_service.dart`) are in English. Match whichever language surrounds the code you're editing.

## Key dependencies

- **`youtube_explode_dart`** — the actual YouTube audio extraction/download engine (`services/youtube_service.dart`). Chosen because it needs no API key/auth and resolves audio-only stream manifests directly. **Note:** the README frames this as *the* YouTube library, but the code has since added `dart_ytmusic_api` as the primary metadata/search/playlist path — `youtube_explode_dart` is now both that path's fallback *and* the only engine that can actually download audio (YTMusic's API has no download support).
- **`just_audio` + `audio_service`** — the playback engine. `just_audio` decodes/plays local files; `audio_service` wraps it for background playback, lock-screen/notification controls, and OS media-session integration (`services/audio_player_handler.dart`). Chosen together because `just_audio` alone has no background/lock-screen support on Android.
- **`sqflite`** — the entire persistence layer (`services/database_helper.dart`): songs, playlists, the join table, the download queue, and play history all live in one SQLite file. Chosen for reliable structured local storage with the app offline-first by design.
- **`provider`** — the sole state-management dependency; chosen for low ceremony over Bloc/Riverpod, fitting a small, single-maintainer codebase.
