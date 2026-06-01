import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_service/audio_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/youtube_service.dart';
import 'music_provider.dart';
import '../services/audio_player_handler.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

class DownloadProvider with ChangeNotifier {
  final YoutubeService _youtubeService = YoutubeService();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  MusicProvider? musicProvider;
  AudioPlayerHandler? audioHandler;

  bool _isDownloading = false;
  double _progress = 0.0;
  String _currentTitle = '';
  String _statusMessage = '';
  String? _errorMessage;

  // Cancellation flag for the queue processor
  bool _cancelRequested = false;
  // Holds the id of the currently processed queue item (if any)
  int? _currentQueueId;

  // Public method to request cancellation of ongoing and pending downloads
  Future<void> cancelAllDownloads() async {
    _downloadSessionId++;
    _cancelRequested = true;
    await _dbHelper.clearDownloadQueue();
    _resetDownloadUi(clearTitle: true, status: 'Descargas canceladas.');
  }

  // Clear pending downloads for a specific playlist
  void clearQueueForPlaylist(String playlistId) {
    _dbHelper.clearQueueForPlaylist(playlistId);
    // If currently processing an item from this playlist, request cancellation
    if (_currentQueueId != null) {
      _cancelRequested = true;
    }
    notifyListeners();
  }

  int _sessionTotal = 0;
  int _sessionCompleted = 0;
  bool _isProcessingQueue = false;
  int _downloadSessionId = 0;
  DateTime? _downloadStartedAt;
  Timer? _elapsedTicker;

  bool get isDownloading => _isDownloading;
  double get progress => _progress;
  String get currentTitle => _currentTitle;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  Duration get downloadElapsed => _downloadStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(_downloadStartedAt!);

  static const int _downloadNotificationId = 888;
  static const String _notificationChannelId = 'com.heardy.app.downloads';
  static const String _notificationChannelName = 'Heardy Descargas';

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Initializes queue on startup — clears any leftover items from previous sessions.
  Future<void> initQueue() async {
    await _dbHelper.clearDownloadQueue();
  }

  /// Cancels any in-flight work and clears the persistent queue before a new session.
  Future<void> prepareForNewDownloads() async {
    _downloadSessionId++;
    _cancelRequested = true;
    await _dbHelper.clearDownloadQueue();
    _resetDownloadUi(clearTitle: true);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_isProcessingQueue && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _isProcessingQueue = false;
    _cancelRequested = false;
  }

  void _resetDownloadUi({bool clearTitle = false, String status = ''}) {
    _stopDownloadClock();
    _isDownloading = false;
    _progress = 0.0;
    _statusMessage = status;
    _errorMessage = null;
    if (clearTitle) _currentTitle = '';
    notifyListeners();
  }

  void _beginDownloadClock() {
    _downloadStartedAt ??= DateTime.now();
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isDownloading) {
        notifyListeners();
      } else {
        _stopDownloadClock();
      }
    });
  }

  void _stopDownloadClock() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _downloadStartedAt = null;
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  /// Downloads a single video by enqueuing it in the persistent SQLite download queue.
  Future<void> downloadVideo(
    String url,
    String playlistId, {
    bool updateGlobalProgress = true,
  }) async {
    await prepareForNewDownloads();

    _errorMessage = null;
    if (updateGlobalProgress) {
      _isDownloading = true;
      _progress = 0.0;
      _currentTitle = '';
      _statusMessage = 'Analizando video...';
      notifyListeners();
    }

    try {
      final videoId = VideoId(url).value;

      // 1. Check if the song is already in this playlist
      final alreadyInPlaylist = await _dbHelper.isSongInPlaylist(playlistId, videoId);
      if (alreadyInPlaylist) {
        if (updateGlobalProgress) {
          _statusMessage = 'La canción ya está en esta lista de reproducción.';
          _isDownloading = false;
          notifyListeners();
        }
        return;
      }

      // 2. Check if the song is already downloaded globally
      final existingSong = await _dbHelper.getSongById(videoId);
      if (existingSong != null && File(existingSong.filePath).existsSync()) {
        final maxOrder = await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1;
        await _dbHelper.addSongToPlaylist(playlistId, existingSong.id, maxOrder + 1);

        if (musicProvider != null) {
          await musicProvider!.loadSongsForPlaylist(playlistId);
          await musicProvider!.loadPlaylists();
        }

        // Dynamic update to active player queue if the same playlist is currently playing
        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == playlistId && audioHandler != null) {
          final mediaItem = MediaItem(
            id: existingSong.id,
            album: musicProvider?.playlists.firstWhere((p) => p.id == playlistId).name ?? '',
            title: existingSong.title,
            artist: existingSong.artist,
            duration: Duration(seconds: existingSong.duration),
            artUri: existingSong.artPath.isNotEmpty ? Uri.file(existingSong.artPath) : null,
            extras: {
              'filePath': existingSong.filePath,
              'artPath': existingSong.artPath,
            },
          );
          await audioHandler!.addQueueItem(mediaItem);
        }

        if (updateGlobalProgress) {
          _isDownloading = false;
          _statusMessage = '¡Añadida canción existente a la lista!';
          notifyListeners();
        }
        return;
      }

      // 3. Add to queue and trigger process
      await _dbHelper.addToDownloadQueue(videoId, playlistId);
      
      if (updateGlobalProgress) {
        _sessionTotal = 1;
        _sessionCompleted = 0;
      }

      // Trigger queue processing
      processQueue();
    } catch (e) {
      if (updateGlobalProgress) {
        _isDownloading = false;
        _errorMessage = e.toString();
        _statusMessage = 'Error en la descarga';
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Iterates and enqueues a complete YouTube playlist into the persistent SQLite download queue.
  Future<void> downloadPlaylist(String playlistUrl, String targetPlaylistId) async {
    await prepareForNewDownloads();

    _isDownloading = true;
    _progress = 0.0;
    _currentTitle = '';
    _statusMessage = 'Analizando lista de reproducción...';
    _errorMessage = null;
    notifyListeners();

    try {
      await WakelockPlus.enable();

      // Resolve all video IDs in the playlist
      final videoIds = await _youtubeService.getPlaylistVideoIds(playlistUrl);
      if (videoIds.isEmpty) {
        throw Exception("La lista de reproducción está vacía o es privada.");
      }

      int addedCount = 0;
      int existingLinkCount = 0;

      for (final videoId in videoIds) {
        // Check duplicate in playlist
        final alreadyInPlaylist = await _dbHelper.isSongInPlaylist(targetPlaylistId, videoId);
        if (alreadyInPlaylist) {
          continue; // Skip completely
        }

        // Check duplicate globally
        final existingSong = await _dbHelper.getSongById(videoId);
        if (existingSong != null && File(existingSong.filePath).existsSync()) {
          // Just link it to the playlist
          final maxOrder = await _dbHelper.getMaxOrderForPlaylist(targetPlaylistId) ?? -1;
          await _dbHelper.addSongToPlaylist(targetPlaylistId, existingSong.id, maxOrder + 1);
          existingLinkCount++;
          continue;
        }

        // Add to persistent SQLite download queue
        await _dbHelper.addToDownloadQueue(videoId, targetPlaylistId);
        addedCount++;
      }

      // Update MusicProvider to show linked songs immediately
      if (existingLinkCount > 0) {
        if (musicProvider != null) {
          await musicProvider!.loadSongsForPlaylist(targetPlaylistId);
          await musicProvider!.loadPlaylists();
        }

        // If currently playing, update queue
        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == targetPlaylistId && audioHandler != null) {
          final songs = await _dbHelper.getSongsForPlaylist(targetPlaylistId);
          for (final song in songs) {
            final mediaItem = MediaItem(
              id: song.id,
              album: musicProvider?.playlists.firstWhere((p) => p.id == targetPlaylistId).name ?? '',
              title: song.title,
              artist: song.artist,
              duration: Duration(seconds: song.duration),
              artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
              extras: {
                'filePath': song.filePath,
                'artPath': song.artPath,
              },
            );
            await audioHandler!.addQueueItem(mediaItem);
          }
        }
      }

      if (addedCount > 0) {
        _sessionTotal += addedCount;
        _statusMessage = 'Añadidos $addedCount videos a la cola de descarga.';
        notifyListeners();
        
        // Start processing queue if not already running
        processQueue();
      } else {
        _isDownloading = false;
        _statusMessage = 'Todos los videos ya están en la lista.';
        notifyListeners();
      }
    } catch (e) {
      _isDownloading = false;
      _errorMessage = e.toString();
      _statusMessage = 'Error descargando la lista';
      notifyListeners();
    } finally {
      await WakelockPlus.disable();
    }
  }

  /// Background processor loop that processes SQLite queue items sequentially.
  /// Includes retry logic (max 2 retries per item) and a cooldown between downloads.
  Future<void> processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    final sessionId = _downloadSessionId;

    try {
      await WakelockPlus.enable();
      bool isFirstItem = true;

      while (true) {
        if (sessionId != _downloadSessionId || _cancelRequested) {
          break;
        }

        final queueItems = await _dbHelper.getDownloadQueue();
        if (queueItems.isEmpty) {
          break;
        }

        if (!isFirstItem) {
          await Future.delayed(const Duration(seconds: 5));
        }
        isFirstItem = false;

        final nextItem = queueItems.first;
        final int queueId = nextItem['id'] as int;
        final String videoId = nextItem['videoId'] as String;
        final String playlistId = nextItem['playlistId'] as String;

        final playlistExists = await _dbHelper.getPlaylistById(playlistId) != null;
        if (!playlistExists) {
          await _dbHelper.removeFromDownloadQueue(queueId);
          continue;
        }

        _currentQueueId = queueId;
        final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
        final itemStarted = DateTime.now();
        const attemptBudget = Duration(minutes: 10);
        const maxAttempts = 2;

        _beginDownloadClock();

        bool success = false;
        String? lastFailureReason;
        for (int attempt = 0; attempt < maxAttempts && !success; attempt++) {
          if (sessionId != _downloadSessionId || _cancelRequested) break;

          try {
            _isDownloading = true;
            _errorMessage = null;
            if (attempt == 0) {
              _progress = 0.0;
            } else {
              _statusMessage =
                  'Reintentando (${attempt + 1}/$maxAttempts)...';
              notifyListeners();
            }
            notifyListeners();

            await _downloadVideoDirectly(
              videoUrl,
              playlistId,
              sessionId: sessionId,
              attempt: attempt,
            ).timeout(attemptBudget, onTimeout: () {
              throw TimeoutException(
                'Intento ${attempt + 1}: sin completarse en '
                '${_formatDuration(attemptBudget)}',
              );
            });

            success = true;
          } catch (e) {
            if (sessionId != _downloadSessionId) break;
            final totalElapsed = DateTime.now().difference(itemStarted);
            lastFailureReason = _friendlyDownloadError(
              e,
              elapsed: totalElapsed,
              attempt: attempt + 1,
              maxAttempts: maxAttempts,
            );
            print("Attempt ${attempt + 1}/$maxAttempts failed for $videoId: $e");
            if (attempt < maxAttempts - 1) {
              final isRateLimit = _isRateLimitError(e);
              _statusMessage = isRateLimit
                  ? 'YouTube limitó las peticiones. Esperando 90s... '
                      '(${attempt + 2}/$maxAttempts)'
                  : 'Reintentando en unos segundos... '
                      '(${attempt + 2}/$maxAttempts)';
              _progress = 0.0;
              notifyListeners();
              await Future.delayed(
                Duration(seconds: isRateLimit ? 90 : 5),
              );
            }
          }
        }

        await _dbHelper.removeFromDownloadQueue(queueId);
        _currentQueueId = null;

        if (!success && sessionId == _downloadSessionId) {
          _errorMessage = lastFailureReason ??
              'No se pudo descargar la canción después de $maxAttempts intentos.';
          _statusMessage = 'Error en la descarga';
          _isDownloading = false;
          notifyListeners();
          print("Permanently failed to download $videoId after $maxAttempts attempts.");
        }
      }
    } finally {
      if (sessionId == _downloadSessionId) {
        _isProcessingQueue = false;
        if (_errorMessage == null) {
          _resetDownloadUi(clearTitle: true);
          _sessionTotal = 0;
          _sessionCompleted = 0;
        }
      } else {
        _isProcessingQueue = false;
      }
      try { await WakelockPlus.disable(); } catch (_) {}
    }
  }

  /// Downloads a single video directly (called by the queue processor).
  Future<void> _downloadVideoDirectly(
    String url,
    String playlistId, {
    required int sessionId,
    int attempt = 0,
  }) async {
    await WakelockPlus.enable();

    DateTime? lastUiUpdate;
    int lastNotifiedPercent = -1;

    void onDownloadProgress(double p) {
      _progress = p;
      if (p > 0 && _currentTitle.isNotEmpty) {
        _statusMessage = _sessionTotal > 0
            ? 'Descargando ${_sessionCompleted + 1} de $_sessionTotal: $_currentTitle'
            : 'Descargando: $_currentTitle';
      }
      final percent = (p * 100).toInt();
      final now = DateTime.now();
      final shouldUpdateUi = percent >= 100 ||
          percent == 0 ||
          lastUiUpdate == null ||
          now.difference(lastUiUpdate!).inMilliseconds >= 300 ||
          percent - lastNotifiedPercent >= 2;

      if (!shouldUpdateUi) return;

      lastUiUpdate = now;
      lastNotifiedPercent = percent;
      notifyListeners();

      if (_currentTitle.isNotEmpty &&
          (percent % 5 == 0 || percent >= 99)) {
        _showProgressNotification(_currentTitle, percent);
      }
    }

    try {
      if (attempt == 0) {
        _statusMessage = 'Iniciando descarga...';
      }
      notifyListeners();

      final result = await _youtubeService.downloadVideoWithAudio(
        url,
        onMetadata: (title) {
          _currentTitle = title;
          _statusMessage = _sessionTotal > 0
              ? 'Descargando ${_sessionCompleted + 1} de $_sessionTotal: $title'
              : 'Descargando: $title';
          notifyListeners();
          _showProgressNotification(title, 0);
        },
        onPhase: (phase) {
          switch (phase) {
            case 'metadata':
              _statusMessage = 'Obteniendo información del video...';
              break;
            case 'manifest':
              _statusMessage = _currentTitle.isNotEmpty
                  ? 'Preparando enlace: $_currentTitle'
                  : 'Preparando enlace de descarga...';
              break;
            case 'downloading':
              if (_currentTitle.isNotEmpty) {
                _statusMessage = _sessionTotal > 0
                    ? 'Descargando ${_sessionCompleted + 1} de $_sessionTotal: $_currentTitle'
                    : 'Descargando: $_currentTitle';
              }
              break;
          }
          notifyListeners();
        },
        onProgress: onDownloadProgress,
        isCancelled: () => _cancelRequested || sessionId != _downloadSessionId,
      );

      final videoId = result['videoId'] as String;
      final title = result['title'] as String;
      final artist = result['artist'] as String;
      final duration = result['duration'] as Duration;
      final format = result['format'] as String;
      final localAudioPath = result['filePath'] as String;
      final localThumbnailPath = result['artPath'] as String;

      _statusMessage = 'Guardando carátula...';
      notifyListeners();

      if (sessionId != _downloadSessionId) {
        throw Exception('Download cancelled');
      }

      final song = Song(
        id: videoId,
        title: title,
        artist: artist,
        duration: duration.inSeconds,
        filePath: localAudioPath,
        artPath: localThumbnailPath,
        format: format,
        downloadDate: DateTime.now(),
      );

      await _dbHelper.insertSong(song);

      // 6. Append track to the target playlist
      final maxOrder = await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1;
      await _dbHelper.addSongToPlaylist(playlistId, song.id, maxOrder + 1);

      // Update session progress
      if (_sessionTotal > 0) {
        _sessionCompleted++;
      }

      // 7. Update states
      _progress = 1.0;
      _statusMessage = '¡Descarga completada!';
      notifyListeners();

      // Refresh UI instantly
      if (musicProvider != null) {
        await musicProvider!.loadSongsForPlaylist(playlistId);
        await musicProvider!.loadPlaylists();
      }

      // Dynamic update to active player queue if the same playlist is currently playing
      final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
      if (currentPlayingPlaylistId == playlistId && audioHandler != null) {
        final mediaItem = MediaItem(
          id: song.id,
          album: musicProvider?.playlists.firstWhere((p) => p.id == playlistId).name ?? '',
          title: song.title,
          artist: song.artist,
          duration: Duration(seconds: song.duration),
          artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
          extras: {
            'filePath': song.filePath,
            'artPath': song.artPath,
          },
        );
        await audioHandler!.addQueueItem(mediaItem);
      }

      await _showCompletionNotification(title, true);
    } catch (e) {
      await _showCompletionNotification(_currentTitle.isNotEmpty ? _currentTitle : 'Audio', false);
      rethrow;
    } finally {
      await WakelockPlus.disable();
    }
  }

  // --- NOTIFICATION UTILITIES ---

  Future<void> _showProgressNotification(String title, int progressPercentage) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'Muestra el estado de la descarga activa',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: progressPercentage,
      ongoing: true,
      onlyAlertOnce: true,
    );

    try {
      await flutterLocalNotificationsPlugin.show(
        _downloadNotificationId,
        'Descargando canción...',
        title,
        NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      // Silently ignore notification failures to avoid blocking download queue
      print('Notification error (progress): $e');
    }
  }

  Future<void> _showCompletionNotification(String title, bool isSuccess) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'Notificación de descarga finalizada',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
    );

    try {
      await flutterLocalNotificationsPlugin.show(
        _downloadNotificationId,
        isSuccess ? 'Descarga completada' : 'Error en la descarga',
        isSuccess ? '¡"$title" ya está disponible sin conexión!' : 'Falló la descarga de "$title".',
        NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      // Silently ignore notification failures
      print('Notification error (completion): $e');
    }
  }

  @override
  void dispose() {
    _stopDownloadClock();
    _youtubeService.dispose();
    super.dispose();
  }

  bool _isRateLimitError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('rate limiting') ||
        msg.contains('requestlimitexceeded') ||
        msg.contains('429');
  }

  String _friendlyDownloadError(
    Object e, {
    Duration? elapsed,
    int? attempt,
    int? maxAttempts,
  }) {
    if (_isRateLimitError(e)) {
      final time = elapsed != null ? ' Tiempo total: ${_formatDuration(elapsed)}.' : '';
      return 'YouTube bloqueó temporalmente las descargas (límite de peticiones).$time '
          'Espera 2-3 minutos y vuelve a intentarlo.';
    }
    if (e is TimeoutException) {
      final time = elapsed != null ? _formatDuration(elapsed) : 'varios minutos';
      final tries = attempt != null && maxAttempts != null
          ? ' Tras $attempt intento${attempt > 1 ? 's' : ''} de $maxAttempts.'
          : '';
      return 'La descarga no terminó a tiempo (tiempo total: $time).$tries '
          'Si el progreso no avanzaba, comprueba tu conexión o espera antes de reintentar.';
    }
    final raw = e.toString();
    if (elapsed != null && elapsed.inSeconds > 60) {
      return '${raw.length > 140 ? '${raw.substring(0, 140)}…' : raw} '
          '(tiempo total: ${_formatDuration(elapsed)})';
    }
    if (raw.length > 180) return '${raw.substring(0, 180)}…';
    return raw;
  }
}
