import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:audio_service/audio_service.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/audio_player_handler.dart';
import '../services/playback_state_service.dart';

class MusicProvider with ChangeNotifier {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  List<Playlist> _playlists = [];
  List<Song> _currentPlaylistSongs = [];
  String? _currentPlaylistId;

  List<Playlist> get playlists => _playlists;
  List<Song> get currentPlaylistSongs => _currentPlaylistSongs;
  String? get currentPlaylistId => _currentPlaylistId;

  MusicProvider() {
    loadPlaylists();
  }

  /// Intenta restaurar el estado de reproducción guardado
  Future<void> restorePlaybackState(AudioPlayerHandler audioHandler) async {
    try {
      print('Verificando estado de reproducción guardado...');
      final savedState = await PlaybackStateService.restoreState();
      if (savedState == null) {
        print('No hay estado de reproducción guardado');
        return;
      }

      print('Estado guardado encontrado, iniciando restauración...');

      // Esperar un poco para asegurar que audio_service esté completamente inicializado
      await Future.delayed(const Duration(milliseconds: 500));

      // Obtener datos guardados
      final playlistId = savedState['playlistId'] as String?;
      final currentMediaId = savedState['currentMediaId'] as String;
      final position = savedState['position'] as Duration;
      final queueIds = savedState['queueIds'] as List<String>;
      final isPlaying = savedState['isPlaying'] as bool;
      final shuffleModeStr = savedState['shuffleModeStr'] as String?;
      final loopModeStr = savedState['loopModeStr'] as String?;
      final speed = savedState['speed'] as double?;

      // Cargar la playlist si existe
      if (playlistId != null && playlistId.isNotEmpty) {
        final playlistExists = _playlists.any((p) => p.id == playlistId);
        if (!playlistExists) {
          print('La playlist guardada ya no existe');
          await PlaybackStateService.clearState();
          return;
        }

        await loadSongsForPlaylist(playlistId, updateCurrent: true);
        
        // Esperar un poco más después de cargar las canciones
        await Future.delayed(const Duration(milliseconds: 200));

        // Reconstruir la queue
        final queueSongs = _currentPlaylistSongs.where((song) {
          return queueIds.contains(song.id);
        }).toList();

        if (queueSongs.isEmpty) {
          print('La queue guardada está vacía o inválida');
          await PlaybackStateService.clearState();
          return;
        }

        // Convertir a MediaItems
        final mediaItems = queueSongs.map((song) => MediaItem(
          id: song.id,
          title: song.title,
          artist: song.artist,
          duration: Duration(seconds: song.duration),
          artUri: song.artPath.isNotEmpty
              ? Uri.file(song.artPath)
              : null,
          extras: {'playlist_id': playlistId},
        )).toList();

        // Setear la queue
        try {
          audioHandler.queue.add(mediaItems);
        } catch (e) {
          print('Error seteando queue: $e');
          await PlaybackStateService.clearState();
          return;
        }

        // Encontrar el índice de la canción actual
        final currentIndex = mediaItems.indexWhere((item) => item.id == currentMediaId);
        if (currentIndex == -1) {
          print('Canción actual no encontrada en la queue');
          await PlaybackStateService.clearState();
          return;
        }

        // Ir a la posición con retry en caso de fallo
        try {
          await audioHandler.skipToQueueItem(currentIndex);
          await Future.delayed(const Duration(milliseconds: 100));
          await audioHandler.seek(position);
        } catch (e) {
          print('Error al navegar a la canción: $e');
          await PlaybackStateService.clearState();
          return;
        }

        // Restaurar shuffle y repeat mode
        if (shuffleModeStr != null) {
          try {
            final shuffleMode = AudioServiceShuffleMode.values.firstWhere(
              (mode) => mode.name == shuffleModeStr,
              orElse: () => AudioServiceShuffleMode.none,
            );
            await audioHandler.setShuffleMode(shuffleMode);
          } catch (e) {
            print('Error restaurando shuffle mode: $e');
          }
        }

        if (loopModeStr != null) {
          try {
            final loopMode = AudioServiceRepeatMode.values.firstWhere(
              (mode) => mode.name == loopModeStr,
              orElse: () => AudioServiceRepeatMode.one,
            );
            await audioHandler.setRepeatMode(loopMode);
          } catch (e) {
            print('Error restaurando loop mode: $e');
          }
        }

        // Restaurar velocidad
        if (speed != null && speed > 0) {
          try {
            await audioHandler.player.setSpeed(speed);
          } catch (e) {
            print('Error restaurando velocidad: $e');
          }
        }

        // Solo reproducir si estaba reproduciendo
        if (isPlaying) {
          try {
            await audioHandler.play();
          } catch (e) {
            print('Error iniciando reproducción: $e');
          }
        } else {
          print('Estado restaurado: canción pausada en ${position.inSeconds}s');
        }

        print('Estado de reproducción restaurado exitosamente');
      }
    } catch (e) {
      print('Error restaurando estado de reproducción: $e');
      await PlaybackStateService.clearState();
    }
  }

  /// Fetches all playlists from the database and updates the local cache.
  Future<void> loadPlaylists() async {
    try {
      _playlists = await _dbHelper.getPlaylists();
      notifyListeners();
    } catch (e) {
      print("Error loading playlists: $e");
    }
  }

  /// Loads tracks inside a specific playlist, making them available to play or view.
  Future<void> loadSongsForPlaylist(String playlistId, {bool updateCurrent = true}) async {
    try {
      if (updateCurrent) {
        _currentPlaylistId = playlistId;
      }
      _currentPlaylistSongs = await _dbHelper.getSongsForPlaylist(playlistId);
      notifyListeners();
    } catch (e) {
      print("Error loading songs for playlist $playlistId: $e");
    }
  }

  /// Inserts a new playlist into SQFlite and updates the UI state.
  Future<void> createPlaylist(String name) async {
    try {
      // Check for duplicate names (case-insensitive)
      final existing = _playlists.where((p) => p.name.toLowerCase() == name.toLowerCase()).toList();
      if (existing.isNotEmpty) {
        throw Exception('Ya existe una playlist con ese nombre');
      }

      final newPlaylist = Playlist(
        id: const Uuid().v4(),
        name: name,
        creationDate: DateTime.now(),
      );

      await _dbHelper.insertPlaylist(newPlaylist);
      await loadPlaylists();
    } catch (e) {
      print("Error creating playlist: $e");
      rethrow;
    }
  }

  Future<void> createPlaylistWithId(String id, String name) async {
    try {
      final newPlaylist = Playlist(
        id: id,
        name: name,
        creationDate: DateTime.now(),
      );
      await _dbHelper.insertPlaylist(newPlaylist);
      await loadPlaylists();
    } catch (e) {
      print("Error creating playlist: $e");
    }
  }

  /// Renames a playlist and triggers a reload.
  Future<void> renamePlaylist(String id, String newName) async {
    try {
      await _dbHelper.updatePlaylistName(id, newName);
      await loadPlaylists();
    } catch (e) {
      print("Error renaming playlist: $e");
    }
  }

  /// Updates the original URL of a playlist.
  Future<void> updatePlaylistUrl(String id, String url) async {
    try {
      await _dbHelper.updatePlaylistUrl(id, url);
      await loadPlaylists();
    } catch (e) {
      print("Error updating playlist URL: $e");
    }
  }

  /// Reorders playlists (top to bottom).
  Future<void> reorderPlaylists(List<Playlist> ordered) async {
    try {
      await _dbHelper.reorderPlaylists(ordered.map((p) => p.id).toList());
      await loadPlaylists();
    } catch (e) {
      print("Error reordering playlists: $e");
    }
  }

  /// Starts playback for a playlist from the first track.
  Future<void> playPlaylistFromStart(
    String playlistId,
    AudioPlayerHandler audioHandler,
  ) async {
    final songs = await _dbHelper.getSongsForPlaylist(playlistId);
    if (songs.isEmpty) return;
    final playlist = await _dbHelper.getPlaylistById(playlistId);
    final name = playlist?.name ?? '';
    await _playSongList(audioHandler, songs, songs.first, name);
    _currentPlaylistId = playlistId;
    _currentPlaylistSongs = songs;
    notifyListeners();
  }

  Future<void> playSongInPlaylist(
    String playlistId,
    Song target,
    AudioPlayerHandler audioHandler,
  ) async {
    final songs = await _dbHelper.getSongsForPlaylist(playlistId);
    if (songs.isEmpty) return;
    final playlist = await _dbHelper.getPlaylistById(playlistId);
    await _playSongList(audioHandler, songs, target, playlist?.name ?? '');
    _currentPlaylistId = playlistId;
    _currentPlaylistSongs = songs;
    notifyListeners();
  }

  Future<void> _playSongList(
    AudioPlayerHandler audioHandler,
    List<Song> songs,
    Song target,
    String playlistName,
  ) async {
    final items = songs
        .map(
          (song) => MediaItem(
            id: song.id,
            album: playlistName,
            title: song.title,
            artist: song.artist,
            duration: Duration(seconds: song.duration),
            artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
            extras: {
              'filePath': song.filePath,
              'artPath': song.artPath,
            },
          ),
        )
        .toList();
    await audioHandler.playPlaylist(items, target.id);
  }

  /// Deletes a playlist, cascades joint tables, cleans up active references, and deletes orphaned songs from device.
  Future<void> deletePlaylist(String id) async {
    try {
      // 1. Find all songs in this playlist BEFORE deleting anything
      final songs = await _dbHelper.getSongsForPlaylist(id);

      // 2. For each song, check if it belongs to OTHER playlists (not counting this one)
      final orphanedSongIds = <String>[];
      for (var song in songs) {
        final count = await _dbHelper.getPlaylistCountForSong(song.id);
        // count includes this playlist, so if count <= 1, the song is only in this playlist
        if (count <= 1) {
          orphanedSongIds.add(song.id);
        }
      }

      // 3. Delete the playlist from DB (CASCADE deletes playlist_songs rows)
      await _dbHelper.deletePlaylist(id);

      // 4. Delete orphaned songs (files + DB records)
      for (var songId in orphanedSongIds) {
        await _dbHelper.deleteSong(songId);
      }

      if (_currentPlaylistId == id) {
        _currentPlaylistId = null;
        _currentPlaylistSongs = [];
      }

      await loadPlaylists();
    } catch (e) {
      print("Error deleting playlist: $e");
    }
  }

  /// Dissociates a track from a playlist and deletes the file if it's not in any other playlist.
  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    try {
      await _dbHelper.removeSongFromPlaylist(playlistId, songId);
      
      // Check if song is in any other playlists
      final playlistCount = await _dbHelper.getPlaylistCountForSong(songId);
      if (playlistCount == 0) {
        // Song is not in any playlist anymore, delete the file
        await _dbHelper.deleteSong(songId);
      }
      
      if (_currentPlaylistId == playlistId) {
        await loadSongsForPlaylist(playlistId);
      }
    } catch (e) {
      print("Error removing song from playlist: $e");
    }
  }

  /// Refreshes the audio handler queue when the current playlist is modified
  Future<void> refreshAudioHandlerQueue(AudioPlayerHandler audioHandler) async {
    if (_currentPlaylistId == null || _currentPlaylistSongs.isEmpty) return;
    
    try {
      final playlist = await _dbHelper.getPlaylistById(_currentPlaylistId!);
      if (playlist == null) return;
      
      final songs = await _dbHelper.getSongsForPlaylist(_currentPlaylistId!);
      if (songs.isEmpty) return;
      
      // Get current media item to restore position
      final currentMediaItem = await audioHandler.mediaItem.first;
      final currentSongId = currentMediaItem?.id;
      
      // Rebuild the queue
      final items = songs
          .map(
            (song) => MediaItem(
              id: song.id,
              album: playlist.name,
              title: song.title,
              artist: song.artist,
              duration: Duration(seconds: song.duration),
              artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
              extras: {
                'filePath': song.filePath,
                'artPath': song.artPath,
              },
            ),
          )
          .toList();
      
      // Find the index of the current song
      final currentIndex = currentSongId != null 
          ? items.indexWhere((item) => item.id == currentSongId)
          : -1;
      
      // Reload the queue
      if (currentIndex >= 0) {
        await audioHandler.playPlaylist(items, currentSongId!);
      } else if (items.isNotEmpty) {
        // Current song not found, start from beginning
        await audioHandler.playPlaylist(items, items.first.id);
      }
    } catch (e) {
      print("Error refreshing audio handler queue: $e");
    }
  }

  /// Permanently deletes a track from SQLite and deletes local file and thumbnail.
  Future<void> permanentlyDeleteSong(String songId) async {
    try {
      await _dbHelper.deleteSong(songId);
      if (_currentPlaylistId != null) {
        await loadSongsForPlaylist(_currentPlaylistId!);
      }
    } catch (e) {
      print("Error permanently deleting song: $e");
    }
  }

  /// Deletes every song belonging to a playlist from the device.
  Future<void> deleteAllSongsFromPlaylist(String playlistId) async {
    try {
      await _dbHelper.deleteAllSongsForPlaylist(playlistId);
      if (_currentPlaylistId == playlistId) {
        _currentPlaylistSongs = [];
        notifyListeners();
      }
    } catch (e) {
      print("Error deleting all songs for playlist $playlistId: $e");
    }
  }

  /// Reorders songs within a playlist.
  Future<void> reorderSongsInPlaylist(String playlistId, List<String> songIds) async {
    try {
      await _dbHelper.reorderSongsInPlaylist(playlistId, songIds);
      if (_currentPlaylistId == playlistId) {
        await loadSongsForPlaylist(playlistId);
      }
    } catch (e) {
      print("Error reordering songs in playlist $playlistId: $e");
    }
  }

  /// Resets the active playlist reference and song list to clean up player state.
  void clearPlaybackState() {
    _currentPlaylistId = null;
    _currentPlaylistSongs = [];
    notifyListeners();
  }
}
