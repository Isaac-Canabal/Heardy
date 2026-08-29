// Verifica SyncProvider contra un CloudSource falso, sin red y sin
// AudioPlayerHandler (attachPlayback nunca se llama acá — no hace falta un
// doble de just_audio para probar la subida de historial/biblioteca).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/providers/sync_provider.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/database_helper.dart';

class _FakeCloudSource implements CloudSource {
  int libraryVersion = 0;
  int friendCount = 0;
  List<Map<String, dynamic>> historyRows = [];
  int pushHistoryCalls = 0;
  int pushLibraryCalls = 0;
  int getAccountCalls = 0;
  CloudSourceException? failNextWith;

  @override
  Future<CloudAccount> getAccount() async {
    getAccountCalls++;
    if (failNextWith != null) {
      final e = failNextWith!;
      failNextWith = null;
      throw e;
    }
    return CloudAccount(
      identity: 'firebase:test',
      username: 'isaac',
      libraryVersion: libraryVersion,
      hasLibrary: libraryVersion > 0,
      friendCount: friendCount,
    );
  }

  @override
  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes}) async {
    pushHistoryCalls++;
    if (failNextWith != null) {
      final e = failNextWith!;
      failNextWith = null;
      throw e;
    }
    historyRows.addAll(rows);
    return HistoryPushResult(received: rows.length, stored: rows.length, skippedTooOld: 0);
  }

  @override
  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  }) async {
    pushLibraryCalls++;
    libraryVersion = baseVersion + 1;
    return libraryVersion;
  }

  // --- Sin usar en estos tests ---
  @override
  Future<void> acceptFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<void> clearPresence() async {}
  @override
  Future<void> deleteAccountData() async {}
  @override
  Future<FriendsList> getFriends() => throw UnimplementedError();
  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes}) =>
      throw UnimplementedError();
  @override
  Future<UserLookupResult> lookupUser(String username) => throw UnimplementedError();
  @override
  Future<void> putPresence({required String songId, required int expiresInSeconds}) async {}
  @override
  Future<void> rejectOrCancelFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<void> removeFriend(String username) => throw UnimplementedError();
  @override
  Future<String> sendFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<bool> setShareNowPlaying(bool enabled) async => enabled;
  @override
  Future<String> setUsername(String username) => throw UnimplementedError();
}

void main() {
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_sync_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    final rawDb = await db.database;
    await rawDb.delete('play_history');
    await rawDb.delete('songs');
    await rawDb.delete('playlists');
    await rawDb.delete('playlist_songs');
  });

  Future<String> insertSong(String id) async {
    await db.insertSong(Song(
      id: id,
      title: 't-$id',
      artist: 'a-$id',
      duration: 100,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime.now(),
      uri: 'content://x/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
    ));
    return id;
  }

  test('sube historial no sincronizado y lo marca synced', () async {
    final songId = await insertSong('s1');
    await db.recordPlay(songId, 60);

    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(source.historyRows, hasLength(1));
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, isEmpty);
  });

  test('una fila huérfana (canción borrada) se marca skipped sin llamar a la red', () async {
    final songId = await insertSong('s2');
    await db.recordPlay(songId, 30);
    await db.deleteSong(songId);

    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(source.pushHistoryCalls, 0);
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, isEmpty);
  });

  test('un fallo de red detiene la pasada sin marcar nada como sincronizado', () async {
    final songId = await insertSong('s3');
    await db.recordPlay(songId, 45);

    final source = _FakeCloudSource()
      ..failNextWith = const CloudSourceException(CloudSourceErrorKind.network, 'sin conexión');
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(provider.lastError, isNotNull);
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, hasLength(1));
  });

  test('push de biblioteca se salta si el contenido no cambió desde la última subida', () async {
    await insertSong('s4');
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);

    await provider.syncNow();
    expect(source.pushLibraryCalls, 1);

    await provider.syncNow();
    // Nada cambió en la biblioteca local entre las dos pasadas: el hash de
    // contenido calculado del lado del cliente evita la segunda subida.
    expect(source.pushLibraryCalls, 1);
  });

  test('un cambio real en la biblioteca dispara una subida nueva', () async {
    await insertSong('s5');
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();
    expect(source.pushLibraryCalls, 1);

    await insertSong('s6');
    await provider.syncNow();
    expect(source.pushLibraryCalls, 2);
  });

  test('reentrada: llamar syncNow mientras ya está sincronizando es un no-op', () async {
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    final first = provider.syncNow();
    final second = provider.syncNow();
    await Future.wait([first, second]);
    // Sólo una pasada real corrió — getAccount() no se llamó dos veces en paralelo.
    expect(source.getAccountCalls, 1);
  });
}
