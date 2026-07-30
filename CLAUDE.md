# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Heardy is a Flutter (Android-only) app that downloads music from YouTube/YouTube Music/Spotify and plays it back fully offline. No backend — everything (audio files, thumbnails, lyrics, metadata) lives on-device in SQLite + the filesystem. README.md (Spanish) has the full feature list and dependency rationale.

## Commands

```bash
flutter pub get                  # install dependencies
flutter run                      # run on connected device/emulator (Android only, no iOS config)
flutter build apk                # release APK
flutter analyze                  # static analysis (flutter_lints)
flutter test                     # run tests (no test/ directory exists yet)
flutter clean                    # wipe build/ and .dart_tool/ — use if you hit stale-build/plugin-registration issues
```

No CI config, no `analysis_options.yaml` beyond `flutter_lints` default. Signing config for release builds lives in `android/keystore.properties` (gitignored) and `heardy-release-key.jks`.

## Architecture

### Directory map

```
lib/
├── main.dart                        # entrypoint: DB init, notifications, AudioService init, permission
│                                     # requests, Provider tree wiring, RouteGenerator (only "/" and "/playlist")
├── models/                          # plain data classes, hand-rolled toMap/fromMap/toJson/fromJson
│   ├── song.dart                    # id, title, artist, duration, filePath, artPath, format, downloadDate
│   ├── playlist.dart                # id, name, creationDate, sortOrder, optional originalUrl
│   └── playlist_song.dart           # mirrors playlist_songs join table; mostly unused since DatabaseHelper
│                                     # queries the join table with raw SQL instead
├── providers/                       # ChangeNotifier state holders (see "State management" below)
│   ├── music_provider.dart          # playlists + current playlist songs + cold-start playback restoration
│   ├── download_provider.dart       # the download queue, YouTube/Spotify orchestration, download UI state
│   ├── settings_provider.dart       # theme preset + max search results (SharedPreferences-backed)
│   └── error_provider.dart          # rolling in-memory error log — defined but NOT wired into the app
├── services/                        # business logic, no Flutter widget dependencies
│   ├── database_helper.dart         # SQLite schema, migrations, all CRUD/queries — single source of truth
│   ├── youtube_service.dart         # YouTube extraction/download engine: metadata fetch, stream manifest
│   │                                # resolution, chunked HTTP download, retry/backoff, playlist scraping
│   │                                # fallback, shared download circuit breaker
│   ├── ytmusic_service.dart         # wraps dart_ytmusic_api as primary metadata/search/playlist path, falls
│   │                                # back to youtube_service.dart on failure. Delegates ALL downloading to
│   │                                # YoutubeService (YTMusic API can't download)
│   ├── spotify_service.dart         # scrapes open.spotify.com/embed/* for metadata (no official API); audio
│   │                                # itself still comes from YouTube via YoutubeService.searchAndDownload
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

- `MusicProvider` — owns playlists and the songs of the currently-viewed playlist (queried fresh from SQLite on every mutation, not cached/derived). Also owns playback-state restoration on cold start.
- `DownloadProvider` — owns the download queue and all download/search orchestration (YouTube + Spotify). Wired as `ChangeNotifierProxyProvider2` so it always has live references to `MusicProvider` and `AudioPlayerHandler`.
- `SettingsProvider` — theme preset + max search results, persisted to `SharedPreferences`.

`AudioPlayerHandler` is provided directly via `Provider<AudioPlayerHandler>.value`, not a `ChangeNotifier` — screens read it via `context.read`/`context.watch` and react to its `mediaItem`/`playbackState`/`queue` streams directly.

### Data layer: `DatabaseHelper` (SQLite via sqflite), single source of truth

Tables: `songs`, `playlists`, `playlist_songs` (join table, `ON DELETE CASCADE` both ways, ordered by `orderIndex`), `download_queue` (persists across app restarts/crashes, `source` column for YouTube vs Spotify), `play_history` (top songs/artists this week/month).

Schema changes go through `_onUpgrade` with sequential `if (oldVersion < N)` blocks — bump `version` in `_initDB` and add a new block, never rewrite an existing one. `PRAGMA foreign_keys = ON` (set in `_onConfigure`) is how cascade deletes work.

Songs are content-addressed by `id`: a YouTube video ID, or `spotify_<sanitized>`/Spotify track ID for Spotify-sourced tracks. A song can belong to multiple playlists via `playlist_songs`; deletion always checks `getPlaylistCountForSong` first and only removes the file + row when no other playlist references it (see `deletePlaylist`, `removeSongFromPlaylist`).

**Note:** `addToDownloadQueue` dedupes on `(videoId, playlistId)`, not `videoId` alone (see Download resilience below).

### Download pipeline (`DownloadProvider` + `YTMusicService`/`YoutubeService`/`SpotifyService`)

Downloads are never awaited directly by the UI — everything funnels through a **persistent SQLite-backed queue** (`download_queue` table) so an in-progress batch survives app kill/restart:

1. `downloadVideo` / `downloadPlaylist` / `downloadSpotifyTrack` / `downloadSpotifyCollection` resolve metadata, dedupe, `INSERT` into `download_queue`, call `processQueue()`.
2. `processQueue()` is a self-scheduling loop guarded by `_isProcessingQueue` — pulls up to `_maxConcurrentDownloads` items at a time, fires `_processQueueItem` per item without awaiting, preserving playlist order via `expectedOrderIndex`.
3. Each item retries up to 2 attempts with a 10-minute budget and exponential backoff before being dropped and surfaced as a friendly error (`_friendlyDownloadError`).
4. `cancelAllDownloads()` / `prepareForNewDownloads()` bump `_downloadSessionId` — in-flight downloads check this against their captured session id to bail out cleanly.

`YTMusicService` wraps `dart_ytmusic_api` as primary source, falling back to `YoutubeService`/`youtube_explode_dart` on failure for every operation (metadata, playlist expansion, search) — InnerTube is less prone to blocking but less complete. `YoutubeService` adds: cycling client configs (android/androidVr), retry-with-backoff, a short-lived metadata cache, and a shared static circuit breaker (`_blockedUntil`/`_consecutiveBlocks`) that pauses all concurrent callers together on a hard block instead of each retrying independently and re-triggering it. `SpotifyService` has no official API — scrapes `open.spotify.com/embed/*` `__NEXT_DATA__` JSON for metadata; audio always comes from YouTube via search-and-match by title/artist/duration.

### Playback (`AudioPlayerHandler` extends `BaseAudioHandler` + `just_audio`)

- Queue is backed by `ConcatenatingAudioSource`; items are filtered against `File(path).existsSync()` before being added, so a missing/deleted file is silently skipped.
- Play-history (`play_history` table) recorded via `_startTracking`/`_finalizePlay` once >= 50% of a track's duration is reached, on track change or completion.
- Playback state (queue, current media id, position, shuffle/loop, speed) persisted to `SharedPreferences` on every `playbackEventStream` tick via `PlaybackStateService`; restored on cold start — `main.dart` calls `MusicProvider.restorePlaybackState` from a post-frame callback (not a timing guess), which reloads from SQLite, rebuilds `MediaItem`s (re-attaching `filePath`/`artPath` extras, not persisted), and calls `playPlaylist` or `restorePlaylist`. `restorePlaybackState` is idempotent by real state (`AudioPlayerHandler.hasLoadedSource`), not a "ran once" flag — safe to call more than once, and self-heals if `queue`/`mediaItem` describe a song but the player has no source loaded (see the paused+close bug below).
- **Paused-then-closed player corruption (fixed 2026-07-29): root cause and fix.** `androidStopForegroundOnPause` (package default `true`, never overridden here) demotes the foreground service the moment playback pauses — unlike while playing, a paused app is fully exposed to the OS killing the process outright on task removal, **without ever invoking `onTaskRemoved`**. Two bugs compounded this: (1) `onTaskRemoved` called `_player.stop()` but never cleared `_playlistSource`/`queue`/`mediaItem`, so if the process *did* survive a swipe, those streams kept describing a song the player had already released; (2) restoration only ever ran once (a boolean flag), 800ms after `runApp` — pure timing, no relation to whether restoration was actually needed. Fix: `onTaskRemoved` now clears `_playlistSource`/`queue`/`mediaItem` like `RepairService.fullRepair` does; `AudioPlayerHandler.hasLoadedSource` + the idempotent `restorePlaybackState` above self-heal both when the callback ran (state is just empty, restores normally) and when the process died before it could run (queue/mediaItem still populated but no source loaded → rebuilds directly from what's in memory, no SharedPreferences round-trip needed). Considered `androidStopForegroundOnPause: false` to stop the demotion outright — rejected: it requires `androidNotificationOngoing: false` too (the package asserts on the combination used here) and keeps the notification permanently non-dismissible while paused, a worse cost than the bug it would prevent. **If `RepairService` still turns out to be needed for this specific symptom (broken player after pausing and closing), the self-heal above didn't cover every path — treat that as a signal, not a coincidence.**

### Lyrics (`LyricsService`)

Fetches synced `.lrc` lyrics from LRCLIB (public, keyless) and caches to `<app documents>/lyrics/<songId>.lrc`. Pre-fetched in the background at the end of every download (`_downloadVideoDirectly`/`_downloadSpotifyDirectly`), so typically already cached by the time "now playing" opens.

### Error handling & diagnostics

`LogService` appends download errors to `<app documents>/download_errors.log` (viewable/clearable from Settings). `RepairService.performFullRepair` (manual, from Settings) is a last-resort recovery: scans for corrupted/orphaned files, cleans temp files, checks DB consistency, resets `AudioPlayerHandler`/`MusicProvider` state. Still kept as a general-purpose manual fallback, but as of the fix described under "Playback" above, it should no longer be *necessary* specifically to recover from "paused, closed the app, player is broken on reopen" — that was the actual bug it was silently working around. `ErrorProvider` is **dead/scaffolded code** — not wired into the provider tree, not read by any screen. Most services/providers `print()` liberally for on-device debugging — intentional, not cleanup debt.

### UI structure

`MainShellScreen` hosts 4 bottom-nav tabs over an `IndexedStack`: Home, `AddFromYouTubeScreen` (labeled "Descargas"), Search, Settings — plus a persistent `MiniPlayer`. `PlaylistDetailScreen` and `NowPlayingScreen` are pushed routes. Routing is a manual `onGenerateRoute` switch in `main.dart` (`RouteGenerator`) — only `/` and `/playlist` are registered. `NowPlayingScreen` is the largest screen (dynamic background from cover art via `palette_generator`, synced lyrics, reorderable queue, waveform seek bar backed by `AudioAnalysisService`). `AppTheme` supports three presets (navy/violet/rose) via `SettingsProvider`.

### Android specifics

Background playback: `audio_service` + `flutter_background_service` + `wakelock_plus` (held during active downloads, bracketed in `DownloadProvider`) + a foreground notification channel (`com.heardy.app.audio`). Downloads use a separate channel (`com.heardy.app.downloads`). `min_sdk_android: 21`.

## Download resilience: safeguards to preserve

Read before touching retry/timeout/concurrency logic. Key files: `download_provider.dart` (`processQueue`/`_processQueueItem` — concurrency + outer retry), `youtube_service.dart` (`_isRetryableError`/`_isHardBlockError`/`_getVideoWithFallback`/circuit breaker).

- **Retry layers — don't add a third.** Outer (`_processQueueItem`: 2 attempts, 10-min budget) → per-method (`getVideoInfo`/`downloadVideoWithAudio`: up to 5 attempts, backoff+jitter). `_getVideoWithFallback` makes a single attempt only — a stacked inner retry here previously caused up to 30 real requests per download.
- **`_maxConcurrentDownloads = 1`, deliberately.** YouTube's block is a cumulative per-IP request budget (~12–24 manifest requests), not a rate limit — concurrency and pacing both make it worse. Chunk-level parallelism inside a single download still gives throughput. Don't raise without re-measuring (`tool/pacing_probe.dart`).
- **Shared static circuit breaker** in `YoutubeService` (`_blockedUntil`/`_consecutiveBlocks`) pauses every caller together on a hard block: 403/401/`VideoUnavailableException`/`VideoUnplayableException` (incl. "confirm you're not a bot", both apostrophe variants). Interactive paths (preview/search) cap the wait at 8s and throw instead of freezing the UI (`_interactiveCooldownCap`); background paths wait the full escalating cooldown (up to 180s).
- **`YTMusicService` (InnerTube) is the primary metadata path for downloads too** — `downloadVideoWithAudio` primes `YoutubeService`'s metadata cache via `getSong` before falling back to the fragile watch-page scrape. Always test against `YTMusicService`, never `YoutubeService` directly.
- **No network layer here has a default timeout** (`youtube_explode_dart`, `dart_ytmusic_api`, `dart:io HttpClient`). Any new call site needs an explicit timeout or it can hang forever with nothing logged.
- **Cooldown/backoff waits must be cancellable** — poll `isCancelled` (`YoutubeService._cancellableDelay`, every 300ms) rather than sleeping the full duration, or a cancelled download holds its `_activeVideoIds`/`_activeDownloads` lock for minutes and blocks resubmitting the same video.
- **`addToDownloadQueue` dedupes on `(videoId, playlistId)`, not `videoId` alone** — double-downloading the same video via two playlists is only prevented by `DownloadProvider._activeVideoIds`, not the DB layer.
- **`YTMusicService._ytmusic` is only assigned once `initialize()` succeeds** (a failed init used to leave it permanently non-null-but-broken). `SpotifyService.resolveShortLink` caps redirect recursion at 5 (`_maxRedirects`).

**Dead end, don't revisit without cause:** an on-device n/sig JS challenge solver (`flutter_js`/QuickJS) for `youtube_explode_dart`'s EJS solver. Android-client stream manifests already arrive unthrottled — no `n` or `s=` param (measured 15–21 MB/s on itag 140). Re-run `tool/manifest_probe.dart` to confirm this is still true before implementing anything here.

## Anti-bot wall investigation — status (2026-07-28)

Full detail, open experiment, and reasoning: `docs/investigacion_muro_antibot.md`.

- `VideoUnplayableException`/`VideoUnavailableException` (manifest) and the rarer 403-with-healthy-manifest (bytes) are IP-reputation effects, not code bugs — confirmed by reproducing both on `main`'s code across three different IPs. There appear to be at least two distinct thresholds: one blocks the manifest step, a separate (lighter?) one blocks only byte validation while manifest still succeeds. Not fully disentangled yet.
- `youtube_explode_dart` 3.1.0 does not generate PO Tokens — not migrating libraries over this; see the dead-end note above for the related JS-solver investigation.
- `yt.search.search()` has a reproducible **library bug** (`NoSuchMethodError` on `viewCountText`'s "runs" shape, ~2/3 of queries) — unrelated to the anti-bot wall. Covered by `YTMusicService.searchAndDownload`'s InnerTube-first fallback and by `_isRetryableError` recognizing `NoSuchMethodError`.
- **Before drawing any conclusion from a run, verify IP state with a 2-manifest canary first.** Without it, branch-vs-`main` comparisons are not valid — this session burned multiple runs on a still-blocked IP before catching this.
- **Recovery requires real silence, not periodic canaries — a canary IS traffic and resets the window.** Measured 2026-07-29: probing every 5 min with a 2-manifest canary produced 0/2 for 25+ straight minutes (session estimate for recovery had been 15-40 min). Stopping the probe entirely and waiting in true silence produced a 2/2 pass after only ~10-12 min. Protocol: stop everything network-related, wait in silence, run exactly **one** canary before touching anything else.
- **A passing 2-manifest canary does NOT mean the IP can sustain a real download session — same day, immediately after the above.** The 2/2 canary passed, so a 15-song comparison run started right away; it re-hit the classic wall (`VideoUnplayableException`, "confirm you're not a bot") around song 6 and the circuit breaker escalated through 4 consecutive hard blocks (160s→320s→640s) within the same run, timing out at 15 minutes having gotten through under 10 of 15 songs. A light canary (2 manifest-only requests) and a real download (metadata + manifest + several parallel byte-range chunks, per song) burn budget at very different rates — passing the former is only evidence the IP is *not currently blocked*, not that it has budget for a sustained session. Don't treat a clean canary as a green light to run a long batch unattended; expect to hit the wall again partway and re-check.

## Testing downloads from desktop (no device install needed)

```bash
flutter test test/download_smoke_test.dart
```

Exercises the real download engine (metadata, manifest, chunked download, thumbnail) without an APK rebuild. Uses `YTMusicService`, not `YoutubeService` — the latter misses the InnerTube metadata path the app actually uses. `setUp` must call `YoutubeService.resetCircuitBreaker()` (shared static state across tests, otherwise one blocked test poisons the next). A bot-walled download takes ~10 min to conclude (escalating cooldowns, per-test timeout 12 min) and is reported as an environmental condition, not a failure — any other exception is a real bug.

## Conventions

- **State management: Provider only.** No Riverpod, Bloc, GetX, or Redux. Every stateful piece of app state is a `ChangeNotifier` registered in `main.dart`'s `MultiProvider`. Screens hold local UI state (search text, sort mode) directly in `State` objects rather than lifting it into a provider.
- **File naming:** snake_case files, one primary PascalCase class per file (`music_provider.dart` → `MusicProvider`). Private helpers/fields are `_camelCase`.
- **Two service-instantiation styles coexist:** singleton-via-static-instance (`DatabaseHelper.instance`, `LyricsService.instance`) vs. instantiated-per-owner classes (`YoutubeService`/`YTMusicService`/`SpotifyService`, one per owning provider/screen). `YoutubeService`'s circuit-breaker state is `static` regardless of instance count.
- **Models are hand-rolled, uniformly:** every model implements `toMap()`/`fromMap(Map)`/`toJson()`/`fromJson(String)` by hand — no `json_serializable`/`freezed`/`equatable`. Match this shape for new persisted entities.
- **Fallback-chain pattern for external data:** `YTMusicService` wraps every method in try-primary-API/catch-log/fallback-to-`YoutubeService`. Follow this shape for new YTMusic-backed operations rather than calling `dart_ytmusic_api` directly from UI code.
- **`MediaItem` construction is duplicated, not factored out** across `MusicProvider` (3 places) and `DownloadProvider` (4 places). Match the existing extras keys (`filePath`, `artPath`, `playlist_id`) exactly — `AudioPlayerHandler` reads them by string key.
- **Error handling is print-and-swallow by default:** most `catch (e)` in `services/`/`providers/` `print()` and return a default rather than rethrow — intentional for a single-user offline app with no crash reporting. `LogService.logError` and the download path's `rethrow`s are the deliberate exceptions.
- **Loading flags must reset in a single `finally`**, not at each return site — screens with multiple early exits after `await` (e.g. `_isAnalyzing` in `add_from_youtube_screen.dart`) can otherwise brick the UI on an untested exit path.
- **Spanish throughout:** UI strings, most comments, and `print()` messages are in Spanish; some service-level code (`youtube_service.dart`, `ytmusic_service.dart`) is in English. Match whichever language surrounds the code you're editing.

## Key dependencies

- **`youtube_explode_dart`** — the YouTube audio extraction/download engine (`services/youtube_service.dart`). No API key needed, resolves audio-only stream manifests directly. Now the fallback to `dart_ytmusic_api` for metadata/search/playlist, and the only engine that can actually download (YTMusic's API has no download support).
- **`just_audio` + `audio_service`** — playback engine. `just_audio` decodes/plays local files; `audio_service` wraps it for background playback, lock-screen/notification controls, OS media-session integration.
- **`sqflite`** — the entire persistence layer: songs, playlists, join table, download queue, play history in one SQLite file.
- **`provider`** — sole state-management dependency; low ceremony over Bloc/Riverpod for a small, single-maintainer codebase.
