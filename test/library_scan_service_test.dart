// Exercises LibraryScanService's reconciliation against a fake in-memory SAF
// backend, no Android device needed. Uses sqflite_common_ffi so
// DatabaseHelper's real SQLite schema/queries run as-is on desktop — see
// CLAUDE.md D2/D3 for the rules this verifies.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/library_scan_service.dart';

class _FakeDir {
  final String uri;
  final String name;
  final List<String> childUris = [];
  _FakeDir(this.uri, this.name);
}

class _FakeFile {
  final String uri;
  final String name;
  Uint8List bytes;
  int mtime;
  _FakeFile(this.uri, this.name, this.bytes, this.mtime);
}

class _FakeSafBackend {
  final Map<String, _FakeDir> dirs = {};
  final Map<String, _FakeFile> files = {};
  int _counter = 0;

  String _newUri() => 'fake://node${_counter++}';

  _FakeDir addDir(_FakeDir? parent, String name) {
    final dir = _FakeDir(_newUri(), name);
    dirs[dir.uri] = dir;
    parent?.childUris.add(dir.uri);
    return dir;
  }

  _FakeFile addFile(_FakeDir parent, String name, Uint8List bytes, int mtime) {
    final file = _FakeFile(_newUri(), name, bytes, mtime);
    files[file.uri] = file;
    parent.childUris.add(file.uri);
    return file;
  }

  void unlink(_FakeDir parent, String uri) => parent.childUris.remove(uri);
  void relink(_FakeDir parent, String uri) => parent.childUris.add(uri);
}

class _FakeSafUtil extends SafUtilPlatform {
  final _FakeSafBackend backend;
  _FakeSafUtil(this.backend);

  @override
  Future<List<SafDocumentFile>> list(String uri) async {
    final dir = backend.dirs[uri];
    if (dir == null) return [];
    return dir.childUris.map((childUri) {
      final d = backend.dirs[childUri];
      if (d != null) {
        return SafDocumentFile(uri: d.uri, name: d.name, isDir: true, length: 0, lastModified: 0);
      }
      final f = backend.files[childUri]!;
      return SafDocumentFile(uri: f.uri, name: f.name, isDir: false, length: f.bytes.length, lastModified: f.mtime);
    }).toList();
  }
}

class _FakeSafStream extends SafStreamPlatform {
  final _FakeSafBackend backend;
  _FakeSafStream(this.backend);

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async {
    final file = backend.files[uri];
    if (file == null) throw StateError('no such fake file: $uri');
    final s = start ?? 0;
    final end = count == null ? file.bytes.length : (s + count).clamp(0, file.bytes.length);
    return Uint8List.sublistView(file.bytes, s.clamp(0, file.bytes.length), end);
  }
}

Uint8List _id3v2Header(int tagBodySize) {
  final size = tagBodySize;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, // version 2.3.0
    0x00, // flags: no footer
    (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F, // syncsafe size
    ...List.filled(tagBodySize, 0xAA), // dummy tag body (e.g. embedded cover art)
  ]);
}

Uint8List _id3v1Trailer() {
  return Uint8List.fromList([0x54, 0x41, 0x47, ...List.filled(125, 0x00)]); // "TAG" + fields
}

Uint8List _buildMp3(Uint8List audioPayload, {required int tagBodySize}) {
  return Uint8List.fromList([
    ..._id3v2Header(tagBodySize),
    ...audioPayload,
    ..._id3v1Trailer(),
  ]);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbPath = join(await databaseFactory.getDatabasesPath(), 'heardy.db');
    await databaseFactory.deleteDatabase(dbPath);
  });

  test('rename and tag-edit both preserve song identity and playlist membership; missing files are tombstoned, not deleted', () async {
    final backend = _FakeSafBackend();
    final root = backend.addDir(null, 'Heardy');
    final playlistDir = backend.addDir(root, 'MiPlaylist');

    // A loose file directly in the root has no playlist folder — it should
    // land in the library with no playlist_songs row (the future inbox, D6).
    backend.addFile(root, 'suelta.mp3', _buildMp3(Uint8List.fromList(List.filled(200, 0x11)), tagBodySize: 0), 500);

    // A file type outside .mp3/.mp4/.m4a (D4 scope) must be skipped, not crash the scan.
    backend.addFile(playlistDir, 'readme.txt', Uint8List.fromList('not audio'.codeUnits), 500);

    final audioPayload = Uint8List.fromList(List.generate(5000, (i) => (i * 37 + 11) % 256));
    final originalBytes = _buildMp3(audioPayload, tagBodySize: 20);
    var file = backend.addFile(playlistDir, 'cancion.mp3', originalBytes, 1000);

    SafUtilPlatform.instance = _FakeSafUtil(backend);
    SafStreamPlatform.instance = _FakeSafStream(backend);

    final service = LibraryScanService();
    final db = DatabaseHelper.instance;

    // --- 1. First scan: two new songs, one unsupported file skipped.
    var result = await service.scan(root.uri);
    expect(result.inserted, 2);
    expect(result.unsupported, 1);

    var playlists = await db.getPlaylists();
    expect(playlists.map((p) => p.name), ['MiPlaylist']); // loose file didn't create a playlist
    final playlistId = playlists.first.id;

    var playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.length, 1);
    final song = playlistSongs.first;
    expect(song.uri, file.uri);
    expect(song.hashKind, 'mp3-audio');
    expect(song.missing, false);
    final originalId = song.id;
    final originalHash = song.fileHash;

    // --- 2. Second scan, nothing changed: fast path, no re-hash needed.
    result = await service.scan(root.uri);
    expect(result.unchanged, 2);
    expect(result.inserted, 0);
    expect((await db.getSongById(originalId))!.missing, false);

    // --- 3. Rename: SAF gives the file a brand-new document uri, bytes identical.
    backend.unlink(playlistDir, file.uri);
    final renamed = backend.addFile(playlistDir, 'cancion (1).mp3', originalBytes, 1000);
    result = await service.scan(root.uri);
    expect(result.moved, 1);

    var reloaded = await db.getSongById(originalId);
    expect(reloaded, isNotNull, reason: 'the rename must update the existing row, not create a new one');
    expect(reloaded!.uri, renamed.uri);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'playlist membership must survive a rename');

    // --- 4. Tag edit: same uri, tag body grows (e.g. embedded cover art added), audio payload untouched.
    final editedBytes = _buildMp3(audioPayload, tagBodySize: 500);
    final editedFile = backend.files[renamed.uri]!;
    editedFile.bytes = editedBytes;
    editedFile.mtime = 2000;
    result = await service.scan(root.uri);
    expect(result.updated, 1);

    reloaded = await db.getSongById(originalId);
    expect(reloaded!.fileHash, originalHash, reason: 'hashing the audio payload only must survive a tag edit');
    expect(reloaded.fileSize, editedBytes.length);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'playlist membership must survive a tag edit');

    // --- 5. File removed from disk: tombstoned, not deleted.
    backend.unlink(playlistDir, renamed.uri);
    result = await service.scan(root.uri);
    expect(result.missing, greaterThanOrEqualTo(1));

    reloaded = await db.getSongById(originalId);
    expect(reloaded, isNotNull, reason: 'a missing file must be tombstoned, never deleted outright');
    expect(reloaded!.missing, true);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'tombstoning must not drop playlist membership');

    // --- 6. File reappears: tombstone clears.
    backend.relink(playlistDir, renamed.uri);
    result = await service.scan(root.uri);
    expect(result.unchanged, greaterThanOrEqualTo(1));
    reloaded = await db.getSongById(originalId);
    expect(reloaded!.missing, false);
  });
}
