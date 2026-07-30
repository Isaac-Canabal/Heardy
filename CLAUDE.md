# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Heardy is a Flutter (Android-only) app that downloads music from YouTube/YouTube Music/Spotify and plays it back fully offline. No backend — everything (audio files, thumbnails, lyrics, metadata) lives on-device in SQLite + the filesystem. README.md (Spanish) has the full feature list and dependency rationale.

> **As of 2026-07-30 this description is being retired.** Heardy is pivoting from *downloader* to *local-library player*: the user supplies their own `.mp3`/`.mp4` files and Heardy indexes, organizes and plays them. Read "Pivot to local library" immediately below before touching anything — the decisions there are settled and are not to be re-litigated mid-implementation.

## Pivot to local library (decided 2026-07-30 — settled, do not re-open)

Everything in this section was decided after investigation and measurement. Implement it as written. If a decision turns out to be wrong *in practice*, say so explicitly with the evidence and ask — do not silently pick a different design.

### Where the previous work lives

The entire YouTube/Spotify download layer (~5,500 lines) plus the anti-bot wall investigation is preserved at the annotated git tag **`youtube-downloader-final`** (commit `3e25daf`). This includes `docs/investigacion_muro_antibot.md`, the six `test/` files and five `tool/` probes. Nothing there is lost by deleting it from the working tree; recover any piece with `git checkout youtube-downloader-final -- <path>`. Everything below the "Download pipeline" heading in this file describes code that the pivot deletes and is kept only until Stage 5 lands.

### D1 — Storage access: Storage Access Framework, one persisted tree URI

`minSdkVersion` resolves to **24** (Flutter 3.44's `FlutterExtension.kt` default, `minSdkVersion flutter.minSdkVersion` in `android/app/build.gradle`) and `targetSdk` is **36**. Scoped storage is therefore mandatory and `requestLegacyExternalStorage` is not available (it stopped working at target 30).

The user picks a folder once via `ACTION_OPEN_DOCUMENT_TREE`; the app calls `takePersistableUriPermission` and stores the tree URI in `SharedPreferences`. Heardy creates/uses a `Heardy/` folder inside it, with one subfolder per playlist.

Rejected alternatives, with reasons — **do not revisit**:
- `MANAGE_EXTERNAL_STORAGE`: Play Store's declaration form only accepts file managers, antivirus and a short list of other categories. Media players are explicitly *not* eligible. This would block publication.
- MediaStore + `READ_MEDIA_AUDIO`: does not index `.mp4` as audio, so covering video containers would also require `READ_MEDIA_VIDEO` — and on Android 14+ that permission is subject to the partial-access selector ("allow access to selected videos"), so the user could grant 3 of 30 files without understanding why the rest never appear. Unacceptable for a library scanner.

Consequences that all downstream code must respect:
- **`dart:io File` no longer addresses user media.** Audio is addressed by `content://` URIs. `just_audio`/ExoPlayer plays `content://` natively — pass the URI straight to `AudioSource.uri`.
- Directory enumeration is a `DocumentsContract` cursor query, not `Directory.list()`. Query children in **one batched call per folder** with a projection (`DOCUMENT_ID`, `DISPLAY_NAME`, `SIZE`, `LAST_MODIFIED`, `MIME_TYPE`); a per-child round trip is an IPC each and is far too slow for hundreds of files.
- Intended packages: `saf_util` (tree picking, persisted permission, batched child listing) + `saf_stream` (read/write streams). Validate them at `flutter pub add` time; if they don't cover a case, write a small platform channel rather than falling back to a permission-heavy approach.

### D2 — File identity: hash the audio payload, not the file

A naive `(size + first 64 KB + last 64 KB)` hash breaks on ID3 tag edits, because ID3v2 lives at the *start* of the file and changes both offsets and total size. Editing tags on hand-managed files is a normal thing for this user to do, and a false "new file" verdict would drop the song into the inbox and lose its playlist membership — exactly what the tombstone rule exists to prevent.

**Identity = hash of the audio payload only, at content offsets:**
- MP3: skip the ID3v2 block (10-byte header, syncsafe size field, +10 more if the footer flag is set) and any trailing ID3v1 (last 128 bytes if they start with `TAG`) or APEv2 block.
- MP4/M4A: hash the `mdat` atom payload (metadata lives in `moov/udta/meta/ilst`, which may sit before *or* after `mdat`).
- Hash = MD5 of `(payload length + first 64 KB of payload + last 64 KB of payload)`.
- Store a `hashKind` column (`mp3-audio` / `mp4-mdat` / `raw-file`) so a later parser fix can selectively invalidate. `raw-file` is the fallback when parsing fails — hash the whole file.

**Plus URI continuity as a second matcher.** Reconciliation order during a scan, per file found on disk:
1. URI already in DB and `(size, mtime)` unchanged → skip, no hashing. This is the common case and keeps rescans cheap.
2. URI in DB but `(size, mtime)` changed → **same song row.** Re-hash, update, keep playlist membership. Tags were edited in place.
3. URI unknown → hash → hash matches an existing row → **move or rename.** Update the URI, keep playlist membership.
4. No match → genuinely new song → insert with no `playlist_songs` rows, i.e. it lands in the inbox.

And per DB row *not* found on disk: set `missing = 1`. **Never auto-delete.** A row revived by hash in a later scan comes back with its playlists intact. Only an explicit user action deletes a song row.

The two matchers cover different failures: URI continuity catches tag edits in place, payload hashing catches moves and renames. Only re-encoding *and* moving a file in the same interval looks like a new song, which is the correct verdict anyway.

### D3 — Playlists live in SQLite; folders are an import mechanism only

The subfolder name determines a song's playlist **only on first insert**. After that `playlist_songs` is the sole truth. This preserves multi-playlist membership without duplicating bytes, and keeps `orderIndex`/reordering and all of `PlaylistDetailScreen` working unchanged.

**Sync is one-way: disk → DB.** Moving a song between playlists inside the app must never move or rewrite the file on disk — these are the user's own files and Heardy is not entitled to reorganize them. An explicit "export playlist to folder" action is acceptable later; implicit writes are not.

### D4 — `.mp4`: play the audio track directly, never transcode

ExoPlayer demuxes the container and plays the AAC track with no video output. Extracting to `.mp3` would need `ffmpeg_kit_flutter`, which was **retired in January 2025**, would add 30–60 MB to the APK, and would lose quality to a re-encode. The only case to handle is an `.mp4` with no audio track: mark it invalid during the scan and keep it out of the library.

### D5 — Metadata: `audio_metadata_reader`, with a filename fallback

Pure Dart, no native dependency, reads ID3v1/v2 plus MP4/M4A atoms plus embedded artwork. Because SAF hands out streams rather than paths, copy each file to the cache **once at import**, read the tags, persist them in `songs`, delete the temp copy, and never touch the file for metadata again.

No tags → parse the filename (`Artista - Título`, stripping leading track numbers and junk like `[Official Video]` / `(Lyrics)` / `_320kbps`), album = folder name, artist = "Desconocido", artwork = a gradient generated from the title hash (reuse `palette_generator` / `AppTheme`). **Manual tag editing is in scope, not a nice-to-have** — with hand-imported files, missing or wrong tags are the common case rather than the edge.

**Resolved during Stage 2 implementation (2026-07-30):**
- **Temp copy for tag reading:** `audio_metadata_reader.readMetadata` needs a `dart:io File`, but SAF only hands out streams. `MetadataService.extract` copies the SAF uri to `<temp dir>/heardy_tag_read_<songId>.<ext>` via `SafStream.copyToLocalFile`, reads it, and deletes it in a `finally` — so the copy never survives past that one `extract()` call regardless of success or failure. This only runs on insert and on an in-place tag edit (matcher 1 with changed size/mtime); a move/rename (matcher 2) reuses the cached tags, since the audio payload — and ordinarily its tags — didn't change.
- **Artwork storage: files in the app-private dir, not SQLite blobs.** Reuses the exact convention downloaded songs already use (`youtube_service.dart`'s `downloadThumbnail`: `<app documents>/thumbnails/<id>.<ext>`), one small file per song. Rejected blobs: a large library means many rows with embedded images, which bloats the single `.db` file and forces loading the blob into memory even for list views that only need the title/artist. `artPath` already models "no artwork" as `''`; `MetadataService` leaves it that way when there's no embedded picture — **no placeholder file is ever written to disk**. The title-hash gradient (previous paragraph) is a pure render-time fallback (`AppTheme.gradientForTitle`, wired into `song_tile.dart`/`mini_player.dart`/`now_playing_screen.dart`'s `SmartAlbumArt`), not a generated image — this is what keeps "many songs with no cover art" cheap.
- **Per-field fallback, not all-or-nothing:** if a tag has a title but no artist, the artist still falls back to the filename-derived one (or "Desconocido") rather than discarding the whole filename-parse just because *some* tag existed. Verified by the "partial tags" test case.

### D6 — Inbox for unassigned files: batch screen, never a per-song dialog

No new table required — the inbox is `songs LEFT JOIN playlist_songs ... WHERE playlistId IS NULL`. A list with multi-select, "select all", and a fixed bottom bar "Asignar a…" opening a sheet with the existing playlists plus "crear nueva", able to assign to several playlists in one action. Badge with the pending count on the bottom nav. Importing 30 files at once must cost the user one interaction, not 30.

### D7 — Waveform seek bar: deleted, not ported

Measured, not assumed: **`audio_waveforms` is declared in `pubspec.yaml` but never imported anywhere in `lib/`.** `AudioAnalysisService` (322 lines) does not extract a waveform at all — it reads the whole file with `readAsBytes()` and derives pseudo-amplitudes from byte patterns seeded by `filePath.hashCode`, falling back to `Random()` when that fails. The bars have never corresponded to the audio.

So: delete `audio_analysis_service.dart`, drop the `audio_waveforms` dependency, and collapse `WaveformSeekBar` (`now_playing_screen.dart:1046`) into the plain `SeekBar` that already extends it (`:1278`). This also removes the only component that would have needed a temp file copy under SAF just to render. Do not port a decorative feature into the new architecture.

### D8 — `flutter_background_service` and `wakelock_plus` both go

Verified by grep, not assumed:
- `flutter_background_service` is **imported nowhere in `lib/`** — it appears only in the auto-generated `GeneratedPluginRegistrant.java`. It is dead weight today and contributes nothing to playback.
- `wakelock_plus` is used **only in `download_provider.dart`** (12 call sites, all bracketing downloads). It leaves with the download layer.

`audio_service` alone covers background playback and lock-screen/notification controls: it owns the foreground service declared in `AndroidManifest.xml` with `android:foregroundServiceType="mediaPlayback"`, and the MediaSession that drives the lock screen. Keep the `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` and `WAKE_LOCK` manifest permissions — `audio_service` needs them. **Stage 6 must confirm this on a real device** (background playback, screen off, lock-screen controls, notification actions) before the removal is considered settled.

### D9 — Schema v8: additive, no risky data migration

Add to `songs`: `uri TEXT`, `fileHash TEXT`, `hashKind TEXT`, `fileSize INTEGER`, `modifiedAt INTEGER`, `album TEXT`, `missing INTEGER NOT NULL DEFAULT 0`. Keep `filePath` — legacy downloaded songs in app-private storage keep working. Playback resolves `uri ?? filePath`, so both generations coexist and no user data is rewritten.

New imported songs use `fileHash` as their `id`; legacy rows keep their YouTube video id. `songs`, `playlists`, `playlist_songs` and `play_history` are otherwise unchanged. `download_queue` is dropped in **v9, at Stage 5**, not before — the download code still reads it until then.

### Implementation stages — every stage ends with a compiling, runnable app

Non-negotiable: no stage may leave the project unable to build or the app unable to play music. Run `flutter analyze` at the end of each.

1. **SAF access + scan into SQLite — done 2026-07-30.** `storage_service.dart` (`saf_util`: tree picking via `mkdirp('Heardy')`, persisted permission) and `library_scan_service.dart` (reconciliation per D2 via `saf_stream.readFileBytes`, MD5 of length+head+tail). Schema v8 landed per D9, plus `Song.playablePath` (`uri ?? filePath`). Entry point is a temporary "Biblioteca local (beta)" card in Settings with "Elegir carpeta"/"Escanear" buttons. The old download UI stays fully in place and functional — verified with `flutter build apk --debug`. `test/library_scan_service_test.dart` runs the whole reconciliation lifecycle on desktop (`sqflite_common_ffi` + fake `SafUtilPlatform`/`SafStreamPlatform`, no device needed) and is the reference for how the two matchers are meant to behave — read it before changing scan logic. Not yet done: metadata (title/artist are filename/"Desconocido" placeholders until Stage 2), and real-device verification of the picker/SAF permissions (only exercised via the fake backend and a desktop build so far — do that before considering this stage fully closed).
2. **Metadata — mostly done 2026-07-30.** `metadata_service.dart` wraps `audio_metadata_reader` with the temp-copy/cleanup and filename-fallback rules resolved above; wired into `library_scan_service.dart` on insert and on in-place tag edits. `test/library_scan_service_test.dart` covers full tags (+ embedded cover extraction), no tags (filename parsing), and partial tags (per-field fallback). Placeholder art is now a per-song gradient (`AppTheme.gradientForTitle`) instead of the old fixed color, wired into every album-art fallback site. Not yet done: manual tag editing UI (D5 said in-scope, not built this stage) and real-device verification of the SAF-copy-then-delete step — only exercised via a fake `SafStreamPlatform` on desktop so far.
3. **Playback on URIs — done 2026-07-30.** Every `MediaItem` construction site (3 in `music_provider.dart`, 6 in `download_provider.dart`, 1 in `playlist_detail_screen.dart`) now puts `song.playablePath` (`uri ?? filePath`, `Song.playablePath` added in Stage 1) into the existing `extras['filePath']` key — same key, so `AudioPlayerHandler` didn't need new extras plumbing, just to handle both kinds of values in what's already there. `AudioPlayerHandler._isPlayable`/`_sourceUriFor` replace every `File(path).existsSync()`/`Uri.file(path)` call site (`playPlaylist`, `restorePlaylist`, `addQueueItem`, `addQueueItems`, `_finalizePlay`): a `content://` uri is checked with `SafUtil.exists(uri, false)` (metadata-only, no bytes read) instead of `File`, and a `SafUtil.exists` failure (revoked folder permission, unmounted volume, provider gone) is caught and treated as "not playable" — same outcome as a legacy deleted file, silently skipped from the queue rather than crashing `setAudioSource()`. This live check turned out to subsume the `missing` DB flag rather than needing to thread it through `MediaItem` separately: a tombstoned song's stale uri fails `exists()` too, so one mechanism now covers "known missing since the last scan," "deleted between scans," and "permission revoked" uniformly. `playPlaylist`/`restorePlaylist`'s filters became async (`_filterPlayable`, checks run via `Future.wait` — local SAF/filesystem calls, not network, so no circuit-breaker-style concern) but every caller already `await`s them, so no signature changes rippled outward. `artUri`/notification/lock-screen art needed **no changes** — verified by inspection that all 10 `artUri:` construction sites already build from `song.artPath` (`Uri.file`, never a SAF uri), which Stage 2 already made point at real app-private files for both legacy and imported songs. `PlaybackStateService` and `play_history` needed no changes either — both only ever persisted song ids/strings, never a path shape, so they were never coupled to the choice between `filePath` and `uri` to begin with. Not yet done: real-device verification of `SafUtil.exists` behavior on an actually-revoked permission (only inspected the plugin's contract, not exercised against a live revoke on hardware).
4. **Inbox + batch assignment** per D6. The new tab replaces `AddFromYouTubeScreen` in the bottom nav; the download code still compiles, it is just no longer reachable from the UI.
5. **Prune.** Delete `youtube_service`, `ytmusic_service`, `spotify_service`, `download_provider`, `add_from_youtube_screen`, `download_progress_card`, `log_service`, `error_provider`, `audio_analysis_service`, most of `repair_service`, and the download-era `test/`+`tool/` files. Remove `youtube_explode_dart`, `dart_ytmusic_api`, `flutter_background_service`, `wakelock_plus`, `audio_waveforms` from `pubspec.yaml`. Schema v9 drops `download_queue`. Repoint `search_screen` at the local library. `flutter clean` afterwards — stale plugin registration is the usual failure here.
6. **Device verification and docs.** Confirm D8 on hardware. Rewrite this file's Architecture sections and README.md to describe the local-library app; delete the download-era sections, which by then describe code that no longer exists.

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

Background playback: `audio_service` + `flutter_background_service` + `wakelock_plus` (held during active downloads, bracketed in `DownloadProvider`) + a foreground notification channel (`com.heardy.app.audio`). Downloads use a separate channel (`com.heardy.app.downloads`). The `min_sdk_android: 21` in `pubspec.yaml` is only `flutter_launcher_icons`' setting — the **actual** `minSdkVersion` is 24 and `targetSdk` is 36 (see D1). `flutter_background_service` and `wakelock_plus` are listed here but contribute nothing to playback — see D8.

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
