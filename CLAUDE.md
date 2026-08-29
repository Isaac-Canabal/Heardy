# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This repository is public.** Document architecture and design decisions here; never document credentials,
hostnames, personal infrastructure, or operational/session history. See "Security rules" at the end for what
belongs in this file versus in the gitignored local notes.

## Project overview

Heardy is a Flutter (Android-only) music library and player app. There is no backend for audio: every song's
bytes live on-device, addressed via Android's Storage Access Framework (SAF), and playback is fully offline.
An optional backend exists for two things only — downloading audio from YouTube/Spotify into the local
library, and syncing a lightweight index (titles, playlists, play history) across a user's own devices. The
backend never stores audio and never needs to for the app to work.

Two ways a song enters the library, and this is the load-bearing idea of the whole app: **however a song
arrives, it ends up as one ordinary row in `songs`, indistinguishable from the others.**

1. **Local import** — the user drops files into the SAF folder from outside the app; a scan reconciles disk
   against SQLite.
2. **Download** — the download service writes a new file into the same SAF folder, using the exact same
   content-identity computation the scanner uses. **Acceptance test for this equivalence, everywhere in this
   codebase: download a song, then immediately rescan — it must report `unchanged`, never `inserted`.** If it
   ever reports `inserted`, the downloader and the scanner have diverged on identity, and every future download
   will duplicate itself.

## Core rules

- Every change must leave the app compiling and able to play music. Run `flutter analyze` (and `flutter test`)
  before considering a change finished.
- **State management: Provider only.** No Riverpod, Bloc, GetX, or Redux. Every stateful piece of app state is
  a `ChangeNotifier` registered in `main.dart`'s `MultiProvider`. Screens hold local UI state (search text,
  sort mode) directly in `State` objects rather than lifting it into a provider.
- **Storage access is SAF-only for user media** — see "Local library" below for why. Never reach for
  `dart:io File`, `MANAGE_EXTERNAL_STORAGE`, or MediaStore as a shortcut; those were evaluated and rejected.
- **Sync between the app and any of its data stores is additive, never destructive by default.** A missing
  row/file on one side is treated as "not seen yet," not "delete this" — see D2 and the cloud-sync section.
  Only an explicit user action (a delete button, a confirmed "remove my data") ever deletes something.
- **Downloading is a second import path into the same library, not a parallel subsystem.** Any new download
  source must integrate at the scanner's reconciliation seam, not bypass it.
- **Loading flags reset in a single `finally`**, not at each return site — a `State` with multiple early exits
  after an `await` can otherwise brick its own UI on an untested exit path.
- **Dependency injection for testability.** External-facing services (a download source, a cloud sync client,
  anything that talks to a server or a plugin with no test double) are constructor/`Provider`-injected so
  tests can substitute a fake. Follow this shape for new external dependencies.
- **Models are hand-rolled, uniformly:** every model implements `toMap()`/`fromMap(Map)`/`toJson()`/
  `fromJson(String)` by hand — no `json_serializable`/`freezed`/`equatable`.
- **`MediaItem` construction is duplicated, not factored out**, across the few call sites that build one.
  Match the existing `extras` keys exactly (`filePath`, `artPath`, `playlist_id`) — the audio handler reads
  them by string key.
- **Error handling is print-and-swallow by default** in `services/`/`providers/` — intentional for a
  single-user-per-device app with no crash reporting. Boundary code (parsing a network response, validating a
  payload) should still fail loudly.
- **File naming:** snake_case files, one primary PascalCase class per file. Private helpers/fields are
  `_camelCase`.
- **Spanish throughout:** UI strings, most comments, and `print()` messages are in Spanish; match whichever
  language surrounds the code you're editing. `server/` (Python) follows the same convention.
- Default to writing no comments; add one only when the *why* is genuinely non-obvious (a hidden constraint, a
  workaround for a specific bug, a rejected alternative worth remembering).

## Architecture

### Directory map

```
lib/
├── main.dart                        # entrypoint: DB init, notifications, AudioService init, permission
│                                     # requests, Provider tree wiring, RouteGenerator ("/" and "/playlist")
├── models/
│   ├── song.dart                    # id, title, artist, duration, filePath, artPath, format, uri, fileHash,
│   │                                 # hashKind, fileSize, modifiedAt, album, missing, sourceUrl
│   ├── playlist.dart                # id, name, creationDate, sortOrder, optional originalUrl
│   └── playlist_song.dart           # mirrors the playlist_songs join table
├── providers/                       # ChangeNotifier state holders
│   ├── music_provider.dart          # playlists + current playlist songs + cold-start playback restoration +
│   │                                 # library-root/inbox-count bookkeeping
│   ├── settings_provider.dart       # theme, max search results, language — SharedPreferences-backed
│   ├── auth_provider.dart           # HeardyAuthProvider: account session state, email verification, id token
│   ├── download_provider.dart       # persistent download queue: enqueue, processQueue, retry/backoff,
│   │                                 # cancellation
│   └── sync_provider.dart           # cloud sync orchestrator: history upload, content-hash-gated library
│                                     # push, "now playing" presence publishing off the playback handler
├── services/                        # business logic, no Flutter widget dependencies
│   ├── database_helper.dart         # SQLite schema, migrations, all CRUD/queries — single source of truth
│   ├── storage_service.dart         # SAF library-root lifecycle: pick, recognize, resolve/create per-playlist
│   │                                 # folders
│   ├── library_scan_service.dart    # reconciles the SAF folder into SQLite — the local import path
│   ├── audio_identity.dart          # content-hash of a song's audio payload only; shared by the scanner and
│   │                                 # the downloader so identity never diverges
│   ├── metadata_service.dart        # tag reading wrapper: SAF-copy-then-read, filename fallback, embedded
│   │                                 # cover extraction
│   ├── download_source.dart         # abstract interface + DTOs — the only thing the app knows about "a server"
│   ├── ytdlp_server_source.dart     # the one real DownloadSource implementation: HTTP client for server/
│   ├── download_service.dart        # turns a resolved remote track into a library song: fetch → write tags →
│   │                                 # SAF paste → identity compute → dedupe → insertSong
│   ├── spotify_service.dart         # scrapes public Spotify embed metadata (no official API), no coupling to
│   │                                 # YouTube or dart:io
│   ├── spotify_match.dart           # pure Spotify→YouTube matching by duration proximity
│   ├── audio_player_handler.dart    # audio_service/just_audio bridge: queue, background playback, lock-screen
│   │                                 # controls, play-history recording, playback-state persistence
│   ├── playback_state_service.dart  # SharedPreferences read/write for "resume where I left off"
│   ├── lyrics_service.dart          # fetches/caches synced .lrc lyrics from a public lyrics API
│   ├── translation_service.dart     # line-by-line lyrics translation, disk-cached next to the .lrc
│   ├── cloud_source.dart            # abstract interface + DTOs for the account/sync/friends/presence surface
│   ├── heardy_cloud_source.dart     # the one real CloudSource implementation: HTTP client for server/
│   ├── account_prompt.dart          # pure decision function for the one-time account-linking prompt
│   └── share_image_service.dart     # RepaintBoundary → PNG capture + share-sheet handoff for stats images
├── screens/                         # one file per screen/tab, StatefulWidget + Provider consumers directly
│   ├── main_shell_screen.dart       # bottom-nav shell + persistent MiniPlayer
│   ├── home_screen.dart             # playlist library: create/rename/reorder/delete
│   ├── inbox_screen.dart            # batch triage for songs imported loose in the library root
│   ├── import_screen.dart           # paste a YouTube/Spotify URL → preview → pick playlist → enqueue; also
│   │                                 # the live download-queue UI
│   ├── auth/login_screen.dart       # sign in/register/reset password, "verify your email" interstitial —
│   │                                 # pushed from a screen that needs an account, never a global gate
│   ├── search_screen.dart           # Local/YouTube segmented search
│   ├── playlist_detail_screen.dart  # song list for one playlist: search/sort/reorder/delete/play
│   ├── now_playing_screen.dart      # full player UI
│   ├── settings_screen.dart         # theme picker, library-folder picker, download-server diagnostic,
│   │                                 # account section (sync status, delete-my-data, presence toggle)
│   ├── friends_screen.dart          # exact-match username search, requests, friends list with "now playing"
│   └── friend_profile_screen.dart   # a friend's stats, rendered with the same StatisticsView as one's own
├── widgets/                         # glass_card, mini_player, song_tile, playlist_target_sheet,
│                                     # download_progress_card, statistics_view, username_claim_sheet,
│                                     # share_stats_card
├── l10n/                            # app_es.arb + app_en.arb (versioned); AppLocalizations is generated by
│                                     # `flutter gen-l10n` and is gitignored
└── theme/app_theme.dart             # color presets + a custom mode (user-chosen primary/secondary)

server/                              # FastAPI + yt-dlp microservice — see server/README.md
```

### State management: Provider

- `MusicProvider` — owns playlists and the songs of the currently-viewed playlist (queried fresh from SQLite
  on every mutation). Also owns playback-state restoration on cold start, and inbox/library-version state every
  screen watches to know when to reload.
- `SettingsProvider` — theme, language, and other locally-persisted preferences. Does not hold auth state.
- `DownloadProvider` — the persistent download queue and its processing loop. Reaches the library through a
  callback rather than holding a `MusicProvider` reference, which keeps it unit-testable and a pure
  orchestrator. Knows nothing about HTTP or the server — talks only to `DownloadSource`.
- `HeardyAuthProvider` — wraps the account/auth SDK: session state, email-verification status, and the id
  token sent as `Authorization: Bearer` on server calls. Not a gate on the rest of the app — only the
  screens that talk to the server read `isReady` before letting a network action start.

`AudioPlayerHandler` and `DownloadSource` are provided via `Provider<T>.value`, not as `ChangeNotifier`s —
screens read them via `context.read`/`context.watch` and react to their streams directly.

### Data layer: `DatabaseHelper` (SQLite via sqflite), single source of truth

Tables: `songs`, `playlists`, `playlist_songs` (join table, cascading both ways, ordered by `orderIndex`),
`play_history`, `download_queue` (persists an in-progress download batch across app kill/restart), and
`pending_imports` (a pasted URL that couldn't reach the server at all).

Schema changes go through `_onUpgrade` with sequential `if (oldVersion < N)` blocks — bump `version` in
`_initDB` and add a new block, **never rewrite an existing one**.

Songs are content-addressed: imported/downloaded songs use `id == fileHash` (the audio-payload hash — see
"Local library" below); legacy rows keep whatever id they were created with. `Song.playablePath`
(`uri ?? filePath`) is what actually gets handed to the player, so both generations coexist without a
migration. A song can belong to multiple playlists via `playlist_songs`; deletion always checks
`getPlaylistCountForSong` first, and an explicit delete removes the underlying file too (both `File(filePath)`
for legacy rows and the SAF `uri` for imported/downloaded ones) — the DB row and the real bytes are kept in
sync on every deletion path.

## Local library

### Storage access: SAF, one persisted tree URI

Scoped storage is mandatory on this app's minimum/target SDKs, so audio is addressed by `content://` URIs, not
file paths. The user picks a folder once via `ACTION_OPEN_DOCUMENT_TREE`; the app takes a persistable
permission and stores the tree URI. Heardy creates/uses a `Heardy/` folder inside it, with one subfolder per
playlist.

Rejected alternatives, do not revisit without new evidence:
- `MANAGE_EXTERNAL_STORAGE` — the Play Store's declaration form does not accept media players for this
  permission.
- MediaStore + `READ_MEDIA_AUDIO`/`READ_MEDIA_VIDEO` — doesn't index `.mp4` reliably as audio, and Android 14+'s
  partial-access selector for video makes a library scanner see an arbitrary subset of files with no clear
  signal to the user about why.

Consequences: `dart:io File` never addresses user media — pass `content://` URIs straight into the audio
player, which handles them natively. Directory enumeration is a batched, projected query per folder (id, name,
size, modified time, mime type) — never a per-child round trip, which is far too slow for large libraries.

### File identity: hash the audio payload, not the file

A naive whole-file hash breaks on tag edits (ID3v2 lives at the start of an MP3 and changes both offset and
size on edit). Identity is the hash of the audio payload only, at content offsets — skipping ID3/APEv2 blocks
for MP3, and hashing the media atom for MP4/M4A. A `hashKind` column records which strategy produced the hash,
with a whole-file fallback when parsing fails, so a later parser fix can selectively invalidate.

Reconciliation per file found on disk, in order:
1. Known URI, unchanged size/mtime → skip, no hashing (the common case, keeps rescans cheap).
2. Known URI, changed size/mtime → same song row, re-hash, update, keep playlist membership (a tag edit in
   place).
3. Unknown URI, hash matches an existing row → update the URI, keep playlist membership (a move/rename).
4. No match → new song, inserted with no playlist membership (lands in the inbox).

Per DB row *not* found on disk: mark `missing`, **never auto-delete**. A row later revived by hash comes back
with its playlists intact. Only an explicit user action deletes a song row.

### Playlists live in SQLite; folders are an import mechanism only

A subfolder name determines a song's playlist only on first insert; after that, `playlist_songs` is the sole
truth. Sync between disk and the database is one-way for anything the app didn't put there itself — moving a
song between playlists inside the app never moves or rewrites the file on disk. The one exception, by design:
the app **is** allowed to create new files in the folder the user picked to hold their music (that's what a
download is), and to delete a file the user explicitly asked to delete. What it never does is reorganize,
rename, or rewrite a file the user placed there themselves.

### Playback of both file shapes

ExoPlayer plays a `.mp4`'s AAC track directly with no video output and no transcoding — the only unplayable
case is an `.mp4` with no audio track, which is excluded during scanning. A `content://` uri is existence
-checked via the SAF plugin (metadata-only, no bytes read) instead of `File.existsSync()`; a failed check
(revoked permission, unmounted volume, deleted file) is treated as "not playable" and silently skipped from the
queue.

### Metadata

Tags (ID3/MP4 atoms + embedded artwork) are read via a pure-Dart reader. Because SAF only hands out streams,
each file is copied to a temp location once at import/tag-edit time, read, and the copy deleted immediately
after — never kept around. No tags → parse the filename (`Artist - Title`, stripping track numbers and
bracketed junk), album from the folder name, artist "Unknown", artwork a gradient derived from the title hash.
Falls back per-field, not all-or-nothing — a title with no artist still keeps the title. Manual tag editing is
in scope for this app, not a nice-to-have, since hand-imported files commonly have missing or wrong tags.

Artwork is stored as small per-song files in app-private storage, not SQLite blobs — keeps the database small
and avoids loading images into memory for list views. No placeholder file is ever written for "no artwork";
the gradient fallback is a pure render-time decision.

### Inbox for unassigned files

Any song with no playlist membership shows up in a batch triage screen: multi-select, "select all", assign to
one or more playlists in a single action, or dismiss with a reversible "ignore" flag that the scanner never
touches on its own. Importing many files at once must cost the user one interaction, not one per file.

## Download system

The app never talks to YouTube directly — all extraction fragility lives in a small FastAPI + yt-dlp
microservice (`server/`, see `server/README.md`). This keeps the fragile, frequently-changing part of the
system out of the shipped APK and behind an interface the client barely needs to know about.

- **`DownloadSource`** (`download_source.dart`) is the abstract seam — resolve a single URL, resolve a
  playlist, search, fetch audio, probe connectivity. `YtdlpServerSource` is the only real implementation; a
  different provider would be a new class behind the same interface, not a rewrite.
- Format: original AAC/M4A, never transcoded — this is the only format that needs no new file extension, no
  new hash strategy, and that the tag writer and player both already support natively.
- **Screens call `DownloadSource` directly** for previews/search — no download happens yet, just metadata.
- **`DownloadProvider`** writes rows into a persistent queue table and drains it one job at a time
  (concurrency 1 — extraction is budget-limited per client, not per app), scheduling a timer for the next
  backoff-eligible job rather than sleeping inside its processing loop.
- **A job whose metadata came from a flattened listing (search results, playlist entries, matched tracks) is
  always re-resolved for real before a single byte downloads** — otherwise a channel name or placeholder
  metadata ends up written into the file's tags. A job whose metadata already came from a full resolve (a
  pasted single URL's own preview) skips this, since repeating it would waste a request for nothing.
- **Permanent vs. transient failures are distinguished server-side and mapped to distinct client-side error
  kinds**, each with its own retry policy: a definitively-gone video is dropped immediately; a rate limit or
  anti-bot block reschedules without spending the finite retry budget, waiting for a server-provided or
  reasonable fixed interval; a plain network/transient error retries a small, fixed number of times with
  backoff. Never fabricate a precise wait time to the user for a wait whose real duration isn't known.
- **`DownloadService.download()`** does the actual work once a job is due: fetch to a temp file → write tags
  (so the file is self-describing on disk) → paste into the user's SAF folder → recompute identity from the
  pasted file (never trust a pre-paste path — the document provider may rename on a collision) → dedupe by
  hash against the existing library → insert.
- A background-download batch needs its own Android foreground service (distinct from the one that already
  backs audio playback) so the queue keeps running while the app isn't in the foreground; falling back on app
  resume is a secondary safety net, not the primary mechanism.

### Spotify bridge

Spotify metadata comes from scraping Spotify's own public embed page (no official API needed, no coupling to
YouTube). Matching to a YouTube video happens client-side, interactively, at analyze time — never as a
background queue job, since a background worker has no user present to show a match to or warn about a bad
one. Matching is by **duration proximity only**, never by title/artist string similarity (translations,
"(Official Video)", casing all make string similarity unreliable across platforms); a track with no
close-enough match is dropped from the batch and shown as "won't be downloaded," never downloaded on a guess.
The whole match list is shown once, before a single batch-download action — never one confirmation dialog per
track.

## Authentication

Account identity is delegated to a managed auth provider (Firebase Auth) — this app never stores or sees a
password. Signing in yields a short-lived id token; the download server verifies that token per request
alongside (or instead of) any static API key. A verified email is required before the account can download,
distinct from just having an account.

**Authentication is not a global gate.** Only the screens that actually talk to the server (import, search)
require a signed-in, verified session; everything else in the app (local library, playlists, playback, local
search) works fully offline with no account at all — that's the whole premise of the local-first design and
must not change.

No secret of any kind belongs in this file or in application source under version control. Server-side
secrets are environment variables on the hosting platform; client-side, a build-time value is acceptable
*only* if it is not sensitive on its own — an id token workflow needs no client-embedded server secret at all,
which is the direction this app has moved in and should stay in.

## Cloud sync

The account is also the anchor for a lightweight cross-device index — the metadata a future desktop client
(or a reinstalled phone) needs to reconstruct someone's library and stats without moving any audio.

**The server stores an index, never audio.** Titles, artists, playlists, membership, and play history —
never a SAF `uri`, a local `filePath`, an `artPath`, or anything else that only means something on the
device that produced it. This is what keeps the server from becoming a content host with the legal and
operational weight that implies.

Design rules that follow from that, settled and not to be re-opened without a real reason:

- **Push is full-index, not incremental, and merges by key rather than replacing.** A device with its storage
  unmounted, or one that hasn't synced in a while, must never be able to wipe out data that lives only on
  another device. Full-index push is much simpler to make idempotent and naturally detects real deletions —
  the tradeoff, accepted, is "last write wins" at the whole-library granularity, mitigated by an optimistic
  version check that turns a silent conflict into a visible one instead of silently discarding data.
  Reconciling the very first sync of an account that already has a cloud index (e.g. from a second device) is
  a union by content hash, not a conflict — nothing is ever deleted just because a fresh install hasn't seen it
  yet.
- **History uploads are deduplicated by a natural key derived from data the client already has** (song +
  local timestamp), not a client-generated id — that avoids collisions across devices and lets a user's
  pre-existing local history sync on day one with no separate migration step. Client-reported values that
  could be used to game shared stats (like listened duration) are sanitized server-side, never trusted as-is.
- **A migration path for existing local-only users is opt-in and shown once.** Linking an account *is*
  agreeing that the index and history travel to the server — say so plainly before the user acts, and never
  leave an in-between state of "have an account but nothing synced." Dismissing the prompt must never show it
  again automatically; it stays reachable from settings.
- **A user-facing "erase my cloud data" action is part of the same delivery as the sync feature itself**, not
  a later addition — anyone who links an account and changes their mind needs a way out before there's
  meaningful data to regret uploading.
- **Any live-presence-style feature ("listening now") is opt-in, defaults off, is asked for explicitly once
  (not silently defaulted either way), and expires by itself rather than relying on an explicit "goodbye"
  signal** — a mobile OS can kill a process without running its cleanup code, so any "I stopped" signal must be
  something that expires on its own, computed from how long the currently-playing track has left, not a fixed
  heartbeat interval. No such feature should add a new persistent timer/polling loop to the client.
- **Server logs never combine identity and content in the same line**, for any of these routes. This
  includes being careful that a raw database-driver exception's text can itself contain the values involved in
  the failing query — log the exception type, never its full text, on routes that touch anything privacy
  -sensitive.
- **Any feature that lets one account look up another (friends, usernames) treats "search" as an existence
  oracle and prices it accordingly** rather than pretending it can be fully closed: exact-match only, a daily
  budget per account, and a response that reveals nothing beyond the fact of the match and the relationship —
  never email, size of library, or listening totals to a non-friend.
- A social/friends surface is a pushed route, not a permanent bottom-nav tab, for the same reason the app
  already avoids adding a tab for anything that's usually empty when working as intended.

## Testing

```bash
flutter test                                             # Dart unit + widget tests
flutter analyze                                           # static analysis (flutter_lints)
cd server && test.bat                                      # server unit tests (pure logic, no live DB needed)
flutter test test/download_live_integration_test.dart      # exercises the real download chain against a
                                                             # running server; skips itself cleanly if none is up
```

Pure-logic pieces (no server, no network, no widgets) are unit-tested directly wherever possible — matching
logic, retry/backoff policy, payload validation, SQL-shape tests against a fake connection. Prefer extracting
a pure top-level function specifically so it's testable without rendering a screen, following the existing
pattern in this codebase (e.g. a diff function pulled out of a screen widget, or a decision function pulled
out of a startup callback).

**A `sqflite_common_ffi` + `testWidgets` gotcha:** any `tester.pump()`/`pumpWidget()` following real DB I/O
done outside `tester.runAsync()` hangs forever — a zone issue, not an animation-loop issue. Wrap the whole
interactive body of such a test in one `runAsync`, and use bounded real-delay pump loops instead of
`pumpAndSettle()` when an indeterminate spinner is on screen.

**A known test-coverage gap:** any screen that reads the real audio-playback handler can't be widget-tested in
this codebase — there is no test double for `just_audio`'s platform-channel player object. Extract the
screen's actual logic into a pure, separately-testable function rather than trying to widget-test the screen
itself; building a real fake for the audio player would be the proper fix if more screens need this coverage.

## Development commands

```bash
flutter pub get                  # install dependencies
flutter run                      # run on connected device/emulator (Android only, no iOS config)
flutter build apk                # release APK
flutter analyze                  # static analysis (flutter_lints)
flutter test                     # run tests
flutter clean                    # wipe build/ and .dart_tool/ — use if you hit stale-build/plugin-registration issues
```

No CI config, no `analysis_options.yaml` beyond `flutter_lints` default. Signing config for release builds is
kept out of version control (`android/keystore.properties`, the release keystore itself) — see the gitignored
local notes for where they actually live on this machine; never document that location here.

## Security rules

- **Never commit a secret of any kind** — API keys, tokens, cookies, keystores, `.env` files. Sensitive
  operational detail (where a secret physically lives, real hostnames, which machine runs what) belongs in a
  gitignored local file, never here.
- **Server-side secrets are environment variables**, read from config at startup; a missing required secret
  should fail startup loudly rather than silently degrade (e.g. running a feature that claims a limit exists
  without anywhere to persist it).
- **Never log identity and content together.** Never log the full text of a database exception on a route that
  touches user data — driver exceptions can embed the query's actual values.
- **The server never stores or needs the user's audio.** Only metadata/index data crosses that boundary.
- **Never expose a device-local SAF `uri` (or any local file path) outside the device it came from** — it's
  meaningless elsewhere and can leak folder structure.
- **This file documents architecture and settled decisions, not operational history.** Don't add dated
  session logs, "the user reported X on device Y," real hostnames/IPs, account names, or step-by-step
  credential-rotation procedures here — that material belongs in the gitignored local notes referenced from
  here only as "local operational notes," never by path or content.

## Current work

Active development branch extends the app from a pure offline local-library player into: (1) an optional
YouTube/Spotify download pipeline that writes into the same local library, and (2) an optional cloud sync
layer (accounts, cross-device library/history sync, friends, shared stats) built on top of that. Both are
strictly additive — the app is fully usable offline with no account, by design, and that must stay true.

The cloud-sync layer is now implemented end to end, server and client, with unit/widget test coverage
(pure-logic tests server-side against fakes, no live Postgres; client tests against fake `CloudSource`/HTTP
clients, no live server). What's landed:

- **Server**: account identity (Firebase-only, distinct from the API-key mechanism used for downloads),
  username claim with a cooldown, a library index + play-history sync surface with optimistic-concurrency
  conflict detection, a canonical-pair friendship model (request/accept/remove, one row per pair regardless of
  who asked), per-account daily budgets on the lookup/social endpoints (distinct from the download quota), and
  an in-memory "now playing" presence tracker with a client-computed TTL.
- **Client**: the local schema gained a sync-tracking column pair on play history; a `CloudSource` abstraction
  (mirroring `DownloadSource`) with the one real HTTP implementation; a sync orchestrator that uploads
  unsynced history in batches and pushes the library index only when its content actually changed (a
  client-side content-hash short-circuit, so an unmodified library costs nothing per sync tick); the
  one-time account-linking prompt (shown once, reachable again from settings if dismissed); a username-claim
  sheet invoked from exactly the two places that need one; friends list/request screens and a friend's stats
  profile (reusing the same statistics widgets as the user's own); a share-as-image flow for stats; and
  presence publishing wired off the existing playback-handler streams, gated by an explicit opt-in switch and
  throttled so it costs one request per song actually listened to, never a heartbeat.
- Statistics UI was extracted into reusable, data-driven widgets first (no direct DB access from the widget
  layer), which is what let the friend-profile screen reuse it as-is.

**Deliberate simplification versus the original design notes:** rather than threading an explicit
"library changed" flag through every mutation call site, the sync orchestrator computes a local content hash
of the library index before each sync attempt and skips the network call entirely when it's unchanged since
the last successful push — one mechanism instead of instrumenting every place the library can change.

**Not yet done, and this is the real gap going into next steps:** none of this has been exercised against a
real Postgres instance or a real device. Before relying on it in production: provision the database, confirm
the daily-song-quota and account-usage counters actually survive a server restart (the whole reason they're
persisted rather than in-memory), and walk the real flow on an Android device — link an account, see the
one-time prompt exactly once, sync a real library, add a friend, see "now playing" update, share a stats
image through a real share-sheet target. None of that has run against anything but fakes and a debug build so
far.
