import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/song.dart';
import '../models/playlist.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('heardy.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 8,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future _onConfigure(Database db) async {
    // Enable Foreign Key support in SQLite to allow ON DELETE CASCADE
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future _createDB(Database db, int version) async {
    // Create songs table
    await db.execute('''
      CREATE TABLE songs (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        duration INTEGER NOT NULL,
        filePath TEXT NOT NULL,
        artPath TEXT NOT NULL,
        format TEXT NOT NULL,
        downloadDate TEXT NOT NULL,
        uri TEXT,
        fileHash TEXT,
        hashKind TEXT,
        fileSize INTEGER,
        modifiedAt INTEGER,
        album TEXT,
        missing INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Create playlists table
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        creationDate TEXT NOT NULL,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        originalUrl TEXT
      )
    ''');

    // Create playlist_songs join table with foreign keys and cascade delete
    await db.execute('''
      CREATE TABLE playlist_songs (
        playlistId TEXT,
        songId TEXT,
        orderIndex INTEGER NOT NULL,
        PRIMARY KEY (playlistId, songId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');

    // Create download_queue table
    await db.execute('''
      CREATE TABLE download_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        videoId TEXT NOT NULL,
        playlistId TEXT NOT NULL,
        addedDate TEXT NOT NULL,
        source TEXT DEFAULT 'youtube',
        spotifyTitle TEXT,
        spotifyArtist TEXT,
        spotifyDurationMs INTEGER,
        spotifyThumbnailUrl TEXT,
        expectedOrderIndex INTEGER
      )
    ''');

    // Create play_history table for statistics
    await db.execute('''
      CREATE TABLE play_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        songId TEXT NOT NULL,
        playDate TEXT NOT NULL,
        playDuration INTEGER NOT NULL,
        FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS download_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          videoId TEXT NOT NULL,
          playlistId TEXT NOT NULL,
          addedDate TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE playlists ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0',
      );
      final rows = await db.query('playlists', orderBy: 'creationDate ASC');
      for (var i = 0; i < rows.length; i++) {
        await db.update(
          'playlists',
          {'sortOrder': i},
          where: 'id = ?',
          whereArgs: [rows[i]['id']],
        );
      }
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE playlists ADD COLUMN originalUrl TEXT',
      );
    }
    if (oldVersion < 5) {
      await db.execute("ALTER TABLE download_queue ADD COLUMN source TEXT DEFAULT 'youtube'");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyTitle TEXT");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyArtist TEXT");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyDurationMs INTEGER");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyThumbnailUrl TEXT");
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS play_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          songId TEXT NOT NULL,
          playDate TEXT NOT NULL,
          playDuration INTEGER NOT NULL,
          FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
        )
      ''');
    }
    if (oldVersion < 7) {
      // Add expectedOrderIndex to preserve playlist order during parallel downloads
      await db.execute(
        'ALTER TABLE download_queue ADD COLUMN expectedOrderIndex INTEGER',
      );
    }
    if (oldVersion < 8) {
      // Local-library pivot: SAF-imported songs identify by uri/fileHash
      // instead of filePath. Additive only — legacy rows keep working via
      // Song.playablePath (uri ?? filePath). See CLAUDE.md D9.
      await db.execute('ALTER TABLE songs ADD COLUMN uri TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN fileHash TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN hashKind TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN fileSize INTEGER');
      await db.execute('ALTER TABLE songs ADD COLUMN modifiedAt INTEGER');
      await db.execute('ALTER TABLE songs ADD COLUMN album TEXT');
      await db.execute(
        'ALTER TABLE songs ADD COLUMN missing INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  // --- SONGS CRUD ---

  Future<int> insertSong(Song song) async {
    final db = await database;
    return await db.insert(
      'songs',
      song.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Song>> getSongs() async {
    final db = await database;
    final maps = await db.query('songs', orderBy: 'downloadDate DESC');
    return maps.map((map) => Song.fromMap(map)).toList();
  }

  Future<Song?> getSongById(String id) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Song.fromMap(maps.first);
    } else {
      return null;
    }
  }

  // --- LOCAL LIBRARY (SAF import) ---

  Future<Song?> getSongByUri(String uri) async {
    final db = await database;
    final maps = await db.query('songs', where: 'uri = ?', whereArgs: [uri]);
    return maps.isNotEmpty ? Song.fromMap(maps.first) : null;
  }

  Future<Song?> getSongByHash(String fileHash) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'fileHash = ?',
      whereArgs: [fileHash],
    );
    return maps.isNotEmpty ? Song.fromMap(maps.first) : null;
  }

  /// Marks every previously-imported song (uri IS NOT NULL) as missing.
  /// Call once at the start of a scan; each file actually found on disk
  /// clears its own row's flag via [touchSongFound] as the scan proceeds,
  /// so anything left flagged at the end genuinely wasn't seen this pass.
  Future<void> markAllImportedSongsMissing() async {
    final db = await database;
    await db.update(
      'songs',
      {'missing': 1},
      where: 'uri IS NOT NULL',
    );
  }

  /// Updates a song's location/stats after finding it on disk during a scan
  /// (same uri, or same fileHash under a new uri) and clears its tombstone.
  Future<void> touchSongFound(
    String songId, {
    required String uri,
    required int fileSize,
    required int modifiedAt,
    String? fileHash,
    String? hashKind,
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? artPath,
  }) async {
    final db = await database;
    final values = <String, dynamic>{
      'uri': uri,
      'fileSize': fileSize,
      'modifiedAt': modifiedAt,
      'missing': 0,
    };
    if (fileHash != null) values['fileHash'] = fileHash;
    if (hashKind != null) values['hashKind'] = hashKind;
    if (title != null) values['title'] = title;
    if (artist != null) values['artist'] = artist;
    if (album != null) values['album'] = album;
    if (duration != null) values['duration'] = duration;
    if (artPath != null) values['artPath'] = artPath;
    await db.update('songs', values, where: 'id = ?', whereArgs: [songId]);
  }

  Future<int> getMissingImportedSongCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM songs WHERE uri IS NOT NULL AND missing = 1',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> deleteSong(String songId) async {
    final db = await database;
    final song = await getSongById(songId);

    if (song != null) {
      // 1. Physically delete audio file
      try {
        final audioFile = File(song.filePath);
        if (await audioFile.exists()) {
          await audioFile.delete();
        }
      } catch (e) {
        print("Error deleting audio file: $e");
      }

      // 2. Physically delete thumbnail file
      if (song.artPath.isNotEmpty) {
        try {
          final artFile = File(song.artPath);
          if (await artFile.exists()) {
            await artFile.delete();
          }
        } catch (e) {
          print("Error deleting thumbnail file: $e");
        }
      }
    }

    // 3. Delete DB record. Foreign key CASCADE deletes joint record in playlist_songs.
    await db.delete(
      'songs',
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  // --- PLAYLISTS CRUD ---

  Future<int> insertPlaylist(Playlist playlist) async {
    final db = await database;
    final maxOrder = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT MAX(sortOrder) FROM playlists',
        )) ??
        -1;
    final map = playlist.toMap();
    map['sortOrder'] = maxOrder + 1;
    return await db.insert(
      'playlists',
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Playlist>> getPlaylists() async {
    final db = await database;
    final maps = await db.query('playlists', orderBy: 'sortOrder ASC');
    return maps.map((map) => Playlist.fromMap(map)).toList();
  }

  Future<void> reorderPlaylists(List<String> orderedIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'playlists',
          {'sortOrder': i},
          where: 'id = ?',
          whereArgs: [orderedIds[i]],
        );
      }
    });
  }

  Future<({int songCount, int totalSeconds, String? coverArtPath})>
      getPlaylistSummary(String playlistId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.duration, s.artPath
      FROM playlist_songs ps
      JOIN songs s ON s.id = ps.songId
      WHERE ps.playlistId = ?
      ORDER BY ps.orderIndex ASC
    ''', [playlistId]);

    if (rows.isEmpty) {
      return (songCount: 0, totalSeconds: 0, coverArtPath: null);
    }

    var total = 0;
    for (final row in rows) {
      total += row['duration'] as int? ?? 0;
    }
    final cover = rows.first['artPath'] as String?;
    return (
      songCount: rows.length,
      totalSeconds: total,
      coverArtPath: cover != null && cover.isNotEmpty ? cover : null,
    );
  }

  Future<Playlist?> getPlaylistById(String id) async {
    final db = await database;
    final maps = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Playlist.fromMap(maps.first);
    } else {
      return null;
    }
  }

  Future<int> updatePlaylistName(String id, String newName) async {
    final db = await database;
    return await db.update(
      'playlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updatePlaylistUrl(String id, String url) async {
    final db = await database;
    return await db.update(
      'playlists',
      {'originalUrl': url},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    // Foreign key constraint (ON DELETE CASCADE) will automatically delete associated playlist_songs rows.
    await db.delete(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // --- PLAYLIST SONGS (JOIN) CRUD ---

  Future<int> addSongToPlaylist(String playlistId, String songId, int order) async {
    final db = await database;
    return await db.insert(
      'playlist_songs',
      {
        'playlistId': playlistId,
        'songId': songId,
        'orderIndex': order,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> removeSongFromPlaylist(String playlistId, String songId) async {
    final db = await database;
    return await db.delete(
      'playlist_songs',
      where: 'playlistId = ? AND songId = ?',
      whereArgs: [playlistId, songId],
    );
  }

  Future<List<Song>> getSongsForPlaylist(String playlistId) async {
    final db = await database;
    
    // Join songs and playlist_songs, ordering by orderIndex
    final List<Map<String, dynamic>> results = await db.rawQuery('''
      SELECT s.* FROM songs s
      INNER JOIN playlist_songs ps ON s.id = ps.songId
      WHERE ps.playlistId = ?
      ORDER BY ps.orderIndex ASC
    ''', [playlistId]);

    return results.map((map) => Song.fromMap(map)).toList();
  }

  Future<int?> getMaxOrderForPlaylist(String playlistId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(orderIndex) as maxOrder FROM playlist_songs WHERE playlistId = ?',
      [playlistId],
    );

    if (result.isNotEmpty && result.first['maxOrder'] != null) {
      return result.first['maxOrder'] as int;
    }
    return null;
  }

  Future<int> deletePlaylistSong(String playlistId, String songId) async {
    return await removeSongFromPlaylist(playlistId, songId);
  }

  Future<bool> isSongInPlaylist(String playlistId, String songId) async {
    final db = await database;
    final maps = await db.query(
      'playlist_songs',
      where: 'playlistId = ? AND songId = ?',
      whereArgs: [playlistId, songId],
    );
    return maps.isNotEmpty;
  }

  Future<int> getPlaylistCountForSong(String songId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM playlist_songs WHERE songId = ?',
      [songId],
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<void> reorderSongsInPlaylist(String playlistId, List<String> songIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < songIds.length; i++) {
        await txn.update(
          'playlist_songs',
          {'orderIndex': i},
          where: 'playlistId = ? AND songId = ?',
          whereArgs: [playlistId, songIds[i]],
        );
      }
    });
  }

  // --- DOWNLOAD QUEUE CRUD ---

  Future<int> addToDownloadQueue(
    String videoId,
    String playlistId, {
    int? expectedOrderIndex,
  }) async {
    final db = await database;
    
    // Check if already in queue to prevent duplicate downloads in the queue
    final existing = await db.query(
      'download_queue',
      where: 'videoId = ? AND playlistId = ?',
      whereArgs: [videoId, playlistId],
    );
    if (existing.isNotEmpty) return 0;

    return await db.insert(
      'download_queue',
      {
        'videoId': videoId,
        'playlistId': playlistId,
        'addedDate': DateTime.now().toIso8601String(),
        'source': 'youtube',
        'expectedOrderIndex': expectedOrderIndex,
      },
    );
  }

  Future<int> addSpotifyToDownloadQueue({
    required String spotifyTrackId,
    required String playlistId,
    required String title,
    required String artist,
    required int durationMs,
    String? thumbnailUrl,
    int? expectedOrderIndex,
  }) async {
    final db = await database;

    // Check if already in queue to prevent duplicate downloads in the queue
    final existing = await db.query(
      'download_queue',
      where: 'videoId = ? AND playlistId = ?',
      whereArgs: [spotifyTrackId, playlistId],
    );
    if (existing.isNotEmpty) return 0;

    return await db.insert(
      'download_queue',
      {
        'videoId': spotifyTrackId,
        'playlistId': playlistId,
        'addedDate': DateTime.now().toIso8601String(),
        'source': 'spotify',
        'spotifyTitle': title,
        'spotifyArtist': artist,
        'spotifyDurationMs': durationMs,
        'spotifyThumbnailUrl': thumbnailUrl,
        'expectedOrderIndex': expectedOrderIndex,
      },
    );
  }

  Future<List<Map<String, dynamic>>> getDownloadQueue() async {
    final db = await database;
    return await db.query('download_queue', orderBy: 'id ASC');
  }

  Future<int> removeFromDownloadQueue(int queueId) async {
    final db = await database;
    return await db.delete(
      'download_queue',
      where: 'id = ?',
      whereArgs: [queueId],
    );
  }

  Future<int> clearDownloadQueue() async {
    final db = await database;
    return await db.delete('download_queue');
  }

  Future close() async {
    final db = await database;
    db.close();
  }

  // --- PLAY HISTORY / STATISTICS ---

  Future<int> recordPlay(String songId, int playDuration) async {
    final db = await database;
    return await db.insert(
      'play_history',
      {
        'songId': songId,
        'playDate': DateTime.now().toIso8601String(),
        'playDuration': playDuration,
      },
    );
  }

  String _getStartOfWeek() {
    final now = DateTime.now();
    final daysToSubtract = now.weekday - 1;
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToSubtract));
    return monday.toIso8601String();
  }

  Future<List<Map<String, dynamic>>> getTopSongsThisWeek({int limit = 10}) async {
    final db = await database;
    final startOfWeek = _getStartOfWeek();
    
    final result = await db.rawQuery('''
      SELECT s.id, s.title, s.artist, s.artPath, COUNT(*) as playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE ph.playDate >= ?
      GROUP BY s.id
      ORDER BY playCount DESC
      LIMIT ?
    ''', [startOfWeek, limit]);
    
    return result;
  }

  Future<List<Map<String, dynamic>>> getTopSongsThisMonth({int limit = 10}) async {
    final db = await database;
    final oneMonthAgo = DateTime.now().subtract(Duration(days: 30)).toIso8601String();
    
    final result = await db.rawQuery('''
      SELECT s.id, s.title, s.artist, s.artPath, COUNT(*) as playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE ph.playDate >= ?
      GROUP BY s.id
      ORDER BY playCount DESC
      LIMIT ?
    ''', [oneMonthAgo, limit]);
    
    return result;
  }

  Future<int> getTotalPlaysThisWeek() async {
    final db = await database;
    final startOfWeek = _getStartOfWeek();
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as total
      FROM play_history
      WHERE playDate >= ?
    ''', [startOfWeek]);
    
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getTotalPlaysThisMonth() async {
    final db = await database;
    final oneMonthAgo = DateTime.now().subtract(Duration(days: 30)).toIso8601String();
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as total
      FROM play_history
      WHERE playDate >= ?
    ''', [oneMonthAgo]);
    
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getTotalListenTimeThisWeek() async {
    final db = await database;
    final startOfWeek = _getStartOfWeek();

    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(playDuration), 0) as total
      FROM play_history
      WHERE playDate >= ?
    ''', [startOfWeek]);

    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getTotalListenTimeThisMonth() async {
    final db = await database;
    final oneMonthAgo = DateTime.now().subtract(Duration(days: 30)).toIso8601String();

    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(playDuration), 0) as total
      FROM play_history
      WHERE playDate >= ?
    ''', [oneMonthAgo]);

    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Map<String, dynamic>?> getTopArtistThisWeek() async {
    final db = await database;
    final startOfWeek = _getStartOfWeek();

    final result = await db.rawQuery('''
      SELECT s.artist, COUNT(*) as playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE ph.playDate >= ?
      GROUP BY s.artist
      ORDER BY playCount DESC
      LIMIT 1
    ''', [startOfWeek]);

    if (result.isEmpty) return null;
    return result.first;
  }

  Future<Map<String, dynamic>?> getTopArtistThisMonth() async {
    final db = await database;
    final oneMonthAgo = DateTime.now().subtract(Duration(days: 30)).toIso8601String();

    final result = await db.rawQuery('''
      SELECT s.artist, COUNT(*) as playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE ph.playDate >= ?
      GROUP BY s.artist
      ORDER BY playCount DESC
      LIMIT 1
    ''', [oneMonthAgo]);

    if (result.isEmpty) return null;
    return result.first;
  }

  // Clear queue items for a specific playlist
  Future<int> clearQueueForPlaylist(String playlistId) async {
    final db = await database;
    return await db.delete('download_queue', where: 'playlistId = ?', whereArgs: [playlistId]);
  }

  // Delete all songs belonging to a playlist (files + DB rows) and clear its download queue
  Future<void> deleteAllSongsForPlaylist(String playlistId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Get song IDs linked to the playlist
      final songMaps = await txn.rawQuery('SELECT songId FROM playlist_songs WHERE playlistId = ?', [playlistId]);
      final songIds = songMaps.map((e) => e['songId'] as String).toList();

      // Delete physical files for each song
      for (final id in songIds) {
        final song = await getSongById(id);
        if (song != null) {
          try { await File(song.filePath).delete(); } catch (_) {}
          try { if (song.artPath.isNotEmpty) await File(song.artPath).delete(); } catch (_) {}
        }
      }

      // Delete song rows (cascade will clean playlist_songs)
      if (songIds.isNotEmpty) {
        await txn.delete('songs', where: 'id IN (${List.filled(songIds.length, '?').join(',')})', whereArgs: songIds);
      }

      // Clear any pending download queue for this playlist
      await txn.delete('download_queue', where: 'playlistId = ?', whereArgs: [playlistId]);
    });
  }
}
