import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_service/audio_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/ytmusic_service.dart';
import '../services/youtube_service.dart';
import '../services/lyrics_service.dart';
import 'music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/spotify_service.dart';

import '../services/log_service.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

class DownloadProvider with ChangeNotifier {
  final YTMusicService _youtubeService = YTMusicService();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  MusicProvider? musicProvider;
  AudioPlayerHandler? audioHandler;

  bool _isDownloading = false;
  double _progress = 0.0;
  String _currentTitle = '';
  String _statusMessage = '';
  String? _errorMessage;
  bool _useCooldown = true;

  // Cancellation flag for the queue processor
  bool _cancelRequested = false;
  // Holds the id of the currently processed queue item (if any)
  int? _currentQueueId;
  
  // Configuración de descarga
  // Una canción a la vez — la paralelización de chunks dentro de cada
  // descarga ya provee velocidad óptima y preserva el orden de la playlist.
  //
  // El comentario de arriba decía "una a la vez" mientras la constante estaba en
  // 3: alguien la subió sin actualizarlo. Vuelve a 1 porque la detección de bots
  // de YouTube reacciona al VOLUMEN de peticiones, y con 3 workers cada uno con
  // su cascada de clientes y sus reintentos, una playlist dispara decenas de
  // peticiones casi simultáneas. Medido: 24/24 peticiones secuenciales
  // correctas, mientras que las ráfagas multi-cliente producían fallos
  // constantes. Es el único mitigante real disponible — la librería no puede
  // resolver el reto JS que YouTube exige (ver _requestTimeout en
  // youtube_service.dart y las notas de "Sign in to confirm you're not a bot").
  static const int _maxConcurrentDownloads = 1;
  final Set<int> _activeDownloads = {}; // IDs de descargas activas
  // videoId/spotifyTrackId de descargas activas — evita que la misma pista, encolada
  // para dos playlists distintas antes de terminar, se descargue dos veces en paralelo
  // y ambas escriban al mismo archivo local (<musicDir>/<videoId>.<ext>), corrompiéndolo.
  final Set<String> _activeVideoIds = {};
  bool _isProcessingQueue = false;

  // Public method to request cancellation of ongoing and pending downloads
  Future<void> cancelAllDownloads() async {
    _downloadSessionId = (int.parse(_downloadSessionId) + 1).toString();
    _cancelRequested = true;
    await _dbHelper.clearDownloadQueue();

    await _awaitWorkersDrained(const Duration(seconds: 8));

    _cancelRequested = false;
    _resetDownloadUi(clearTitle: true, status: 'Descargas canceladas.');
  }

  /// Espera a que los workers en vuelo terminen de verdad y suelten sus locks.
  ///
  /// Esto esperaba solo por `_isProcessingQueue`, y esa era la condición
  /// equivocada: `_isProcessingQueue` pertenece al loop despachador de
  /// `processQueue()`, pero las descargas se lanzan con `.ignore()`
  /// (`_processQueueItem(item, sessionId).ignore()`), así que son futures
  /// sueltos que el loop no espera. En cuanto se pone `_cancelRequested = true`,
  /// el despachador corta en su primer `if` y su `finally` pone
  /// `_isProcessingQueue = false` en ~300ms — mientras los 3 workers siguen
  /// vivos. La espera se daba por satisfecha ahí y volvía, dejando workers
  /// zombis de la sesión anterior corriendo dentro de la sesión nueva, todavía
  /// reteniendo `_activeDownloads`/`_activeVideoIds` (que es lo que hace que
  /// `processQueue()` se niegue a despachar) y a punto de pisar la UI al morir.
  /// Lo que hay que esperar son los workers, no el despachador.
  Future<void> _awaitWorkersDrained(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while ((_isProcessingQueue || _activeDownloads.isNotEmpty) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_activeDownloads.isNotEmpty) {
      // Se agotó el presupuesto. Los workers restantes son de una sesión
      // obsoleta y ya no pueden tocar la UI (guarda de sessionId), pero siguen
      // ocupando slots de concurrencia, así que se liberan para que la sesión
      // nueva pueda avanzar.
      //
      // _activeVideoIds NO se limpia a propósito: ese lock es lo único que
      // impide que dos workers descarguen el mismo videoId a la vez y escriban
      // ambos sobre <musicDir>/<videoId>.<ext>, corrompiendo el archivo.
      // Soltarlo aquí reintroduciría justo ese bug. Cada worker zombi quita su
      // propio videoId en su finally, así que el lock se libera solo; como mucho
      // processQueue() posterga ESE video (sigue despachando los demás) hasta
      // que el zombi muera de verdad.
      print('[DownloadProvider] ${_activeDownloads.length} descarga(s) no '
          'terminaron dentro del presupuesto; liberando sus slots '
          '(se conserva el lock por videoId).');
      _activeDownloads.clear();
    }
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
  String _downloadSessionId = '0';
  DateTime? _downloadStartedAt;
  Timer? _elapsedTicker;

  bool get isDownloading => _isDownloading;
  double get progress => _progress;
  String get currentTitle => _currentTitle;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  bool get useCooldown => _useCooldown;
  int get interDownloadDelaySeconds => _interDownloadDelay.inSeconds;
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

  /// Nombre de una playlist para el campo `album` del `MediaItem`, o '' si ya no
  /// existe.
  ///
  /// Los cuatro sitios que construyen MediaItems hacían
  /// `musicProvider?.playlists.firstWhere((p) => p.id == id).name ?? ''`, y ese
  /// `?? ''` sólo cubría que `musicProvider` fuese null: si el provider existía
  /// pero `firstWhere` no encontraba la playlist, lanzaba StateError antes de que
  /// el `??` entrara en juego. Es alcanzable —una descarga dura minutos y la
  /// playlist se puede borrar mientras corre— y hacía que los items restantes
  /// fallaran con un StateError opaco en el log en vez de terminar limpiamente.
  String _playlistName(String playlistId) {
    final playlists = musicProvider?.playlists;
    if (playlists == null) return '';
    for (final p in playlists) {
      if (p.id == playlistId) return p.name;
    }
    return '';
  }

  void setCooldown(bool value) {
    _useCooldown = value;
    // Wires this setting to YoutubeService's shared circuit breaker — previously
    // _useCooldown was read nowhere and had no effect on retry/backoff behavior.
    YoutubeService.circuitBreakerEnabled = value;
    notifyListeners();
  }

  /// Pausa deliberada entre una descarga y la siguiente.
  ///
  /// El muro anti-bot de YouTube se dispara por VOLUMEN de peticiones, y hasta
  /// ahora no había ningún espaciado real: `_maxConcurrentDownloads = 1` limita
  /// la concurrencia, pero el `Future.delayed(800ms)` del final de `processQueue`
  /// sólo separa despachos SIMULTÁNEOS — con un solo slot, el loop se queda
  /// girando en su poll de 300ms y despacha la siguiente canción ~300ms después
  /// de que termine la anterior. O sea, encadenadas.
  ///
  /// POR DEFECTO DESACTIVADO (0), y el motivo está medido — no lo subas sin
  /// volver a medir.
  ///
  /// `tool/pacing_probe.dart` corrió el mismo set de 12 vídeos en cuatro bloques,
  /// alternando 0s y 5s de pausa en orden A,B,B,A (los dos órdenes, para que
  /// ninguna condición se llevara siempre la sesión fresca). Resultado: **42% de
  /// fallo en ambas condiciones**, exactamente igual. Lo que predice el fallo es
  /// el ORDEN del bloque, no el espaciado: 0% -> 8% -> 75% -> 83%, monótono.
  ///
  /// Es decir, el muro no es un límite de peticiones por segundo: es un
  /// presupuesto ACUMULADO por IP. Espaciar no ayuda porque lo que cuenta es el
  /// total, no el ritmo. Y los 150s de pausa entre bloques no bastaron para
  /// recuperarlo — el bloqueo se fue acumulando bloque a bloque.
  ///
  /// El ajuste se conserva porque el mecanismo es correcto y barato, y porque
  /// esto se midió desde una IP de escritorio: una IP móvil (CGNAT, compartida
  /// con muchos usuarios) puede comportarse distinto y merece que el usuario
  /// pueda probarlo. Pero por defecto no se paga un coste que no compra nada.
  Duration _interDownloadDelay = Duration.zero;

  /// 0 desactiva el espaciado. Se acota por arriba para que un valor absurdo no
  /// deje la cola parada de forma indistinguible de un cuelgue.
  void setInterDownloadDelay(int seconds) {
    _interDownloadDelay = Duration(seconds: seconds.clamp(0, 60));
    notifyListeners();
  }

  /// Initializes queue on startup — clears any leftover items from previous sessions.
  Future<void> initQueue() async {
    YoutubeService.circuitBreakerEnabled = _useCooldown;
    await _dbHelper.clearDownloadQueue();
  }

  /// Cancels any in-flight work and clears the persistent queue before a new session.
  Future<void> prepareForNewDownloads() async {
    _downloadSessionId = (int.parse(_downloadSessionId) + 1).toString();
    _cancelRequested = true;
    await _dbHelper.clearDownloadQueue();
    _sessionTotal = 0;
    _sessionCompleted = 0;
    // Sesión nueva: la primera descarga no debe heredar el espaciado pendiente
    // del último despacho de la sesión anterior.
    _lastDispatchAt = null;

    // Drenar de verdad antes de arrancar la sesión nueva (ver
    // _awaitWorkersDrained). Si se vuelve antes de que los workers viejos
    // mueran, el processQueue() nuevo se queda girando contra
    // _maxConcurrentDownloads sin despachar nada.
    await _awaitWorkersDrained(const Duration(seconds: 8));

    _isProcessingQueue = false;
    _cancelRequested = false;
    // La UI se limpia al final: hacerlo antes dejaba que un worker moribundo de
    // la sesión anterior escribiera su mensaje de error encima del estado recién
    // reseteado.
    _resetDownloadUi(clearTitle: true);
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

  void _updateProgress() {
    if (_sessionTotal > 0) {
      _progress = _sessionCompleted / _sessionTotal;
    }
  }

  void _beginDownloadClock() {
    _downloadStartedAt ??= DateTime.now();
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isProcessingQueue) {
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
          // Only update current playlist if user is viewing it
          final updateCurrent = musicProvider!.currentPlaylistId == playlistId;
          await musicProvider!.loadSongsForPlaylist(playlistId, updateCurrent: updateCurrent);
          await musicProvider!.loadPlaylists();
        }

        // Dynamic update to active player queue if the same playlist is currently playing
        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == playlistId && audioHandler != null) {
          final mediaItem = MediaItem(
            id: existingSong.id,
            album: _playlistName(playlistId),
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

      // Resolve all video IDs in the playlist.
      //
      // Esta resolución ocurre ANTES de que exista un solo item en
      // `download_queue`, así que ni el `attemptBudget` de `_processQueueItem`
      // ni `cancelAllDownloads()` la alcanzaban: expandir una playlist grande
      // (scraper paginado + fallback) puede tardar, y hasta ahora no había forma
      // de abortarla. Se le pasa el mismo criterio de staleness que usan los
      // workers, capturado después de `prepareForNewDownloads()` para que sea el
      // id de ESTA sesión.
      final sessionId = _downloadSessionId;
      final videoIds = await _youtubeService.getPlaylistVideoIds(
        playlistUrl,
        isCancelled: () => _cancelRequested || _downloadSessionId != sessionId,
      );
      if (videoIds.isEmpty) {
        throw Exception("La lista de reproducción está vacía o es privada.");
      }

      int addedCount = 0;
      int existingLinkCount = 0;
      // Track the next orderIndex for newly queued items, continuing from
      // songs already linked to the playlist.
      int nextOrder = (await _dbHelper.getMaxOrderForPlaylist(targetPlaylistId) ?? -1) + 1;

      final existingPlaylistSongs = await _dbHelper.getSongsForPlaylist(targetPlaylistId);
      final existingPlaylistIds = existingPlaylistSongs.map((s) => s.id).toSet();
      final allSongs = await _dbHelper.getSongs();
      final allSongsMap = {for (var s in allSongs) s.id: s};

      for (final videoId in videoIds) {
        // Check duplicate in playlist
        final alreadyInPlaylist = existingPlaylistIds.contains(videoId);
        if (alreadyInPlaylist) {
          continue; // Skip completely
        }

        // Check duplicate globally
        final existingSong = allSongsMap[videoId];
        if (existingSong != null && File(existingSong.filePath).existsSync()) {
          // Just link it to the playlist at the correct order position
          await _dbHelper.addSongToPlaylist(targetPlaylistId, existingSong.id, nextOrder);
          existingPlaylistIds.add(existingSong.id);
          nextOrder++;
          existingLinkCount++;
          continue;
        }

        // Add to persistent SQLite download queue with expected order index
        await _dbHelper.addToDownloadQueue(
          videoId,
          targetPlaylistId,
          expectedOrderIndex: nextOrder,
        );
        nextOrder++;
        addedCount++;
      }

      // Update MusicProvider to show linked songs immediately
      if (existingLinkCount > 0) {
        if (musicProvider != null) {
          // Only update current playlist if user is viewing it
          final updateCurrent = musicProvider!.currentPlaylistId == targetPlaylistId;
          await musicProvider!.loadSongsForPlaylist(targetPlaylistId, updateCurrent: updateCurrent);
          await musicProvider!.loadPlaylists();
        }

        // If currently playing, update queue
        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == targetPlaylistId && audioHandler != null) {
          final songs = await _dbHelper.getSongsForPlaylist(targetPlaylistId);
          final mediaItems = <MediaItem>[];
          for (final song in songs) {
            mediaItems.add(MediaItem(
              id: song.id,
              album: _playlistName(targetPlaylistId),
              title: song.title,
              artist: song.artist,
              duration: Duration(seconds: song.duration),
              artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
              extras: {
                'filePath': song.filePath,
                'artPath': song.artPath,
              },
            ));
          }
          if (mediaItems.isNotEmpty) {
            await audioHandler!.addQueueItems(mediaItems);
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
      // Cancelar durante la expansión de la lista no es un fallo: mostrarlo como
      // "Error descargando la lista" pisaba el "Descargas canceladas." que
      // `cancelAllDownloads()` acababa de poner.
      if (YoutubeService.isCancellationError(e)) {
        print('Expansión de la lista cancelada por el usuario');
        _isDownloading = false;
        notifyListeners();
      } else {
        _isDownloading = false;
        _errorMessage = e.toString();
        _statusMessage = 'Error descargando la lista';
        notifyListeners();
      }
    } finally {
      await WakelockPlus.disable();
    }
  }

  String _getSpotifyTrackId(SpotifyTrackInfo track) {
    if (track.spotifyUri != null && track.spotifyUri!.startsWith('spotify:track:')) {
      return track.spotifyUri!.split(':').last;
    }
    // Fallback to a sanitized string
    final sanitized = '${track.artist}_${track.title}'.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return 'spotify_$sanitized';
  }

  Future<void> downloadSpotifyTrack(
    SpotifyTrackInfo track,
    String playlistId, {
    bool updateGlobalProgress = true,
  }) async {
    await prepareForNewDownloads();

    _errorMessage = null;
    if (updateGlobalProgress) {
      _isDownloading = true;
      _progress = 0.0;
      _currentTitle = '';
      _statusMessage = 'Analizando pista...';
      notifyListeners();
    }

    try {
      final spotifyTrackId = _getSpotifyTrackId(track);

      // 1. Check duplicate in playlist
      final alreadyInPlaylist = await _dbHelper.isSongInPlaylist(playlistId, spotifyTrackId);
      if (alreadyInPlaylist) {
        if (updateGlobalProgress) {
          _statusMessage = 'La canción ya está en esta lista de reproducción.';
          _isDownloading = false;
          notifyListeners();
        }
        return;
      }

      // 2. Check global duplicate
      final existingSong = await _dbHelper.getSongById(spotifyTrackId);
      if (existingSong != null && File(existingSong.filePath).existsSync()) {
        final maxOrder = await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1;
        await _dbHelper.addSongToPlaylist(playlistId, existingSong.id, maxOrder + 1);

        if (musicProvider != null) {
          final updateCurrent = musicProvider!.currentPlaylistId == playlistId;
          await musicProvider!.loadSongsForPlaylist(playlistId, updateCurrent: updateCurrent);
          await musicProvider!.loadPlaylists();
        }

        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == playlistId && audioHandler != null) {
          final mediaItem = MediaItem(
            id: existingSong.id,
            album: _playlistName(playlistId),
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

      // 3. Add to download queue
      await _dbHelper.addSpotifyToDownloadQueue(
        spotifyTrackId: spotifyTrackId,
        playlistId: playlistId,
        title: track.title,
        artist: track.artist,
        durationMs: track.durationMs,
        thumbnailUrl: track.thumbnailUrl,
      );

      if (updateGlobalProgress) {
        _sessionTotal = 1;
        _sessionCompleted = 0;
      }

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

  Future<void> downloadSpotifyCollection(
    List<SpotifyTrackInfo> tracks,
    String targetPlaylistId,
  ) async {
    await prepareForNewDownloads();

    _isDownloading = true;
    _progress = 0.0;
    _currentTitle = '';
    _statusMessage = 'Analizando pistas de Spotify...';
    _errorMessage = null;
    notifyListeners();

    try {
      await WakelockPlus.enable();

      int addedCount = 0;
      int existingLinkCount = 0;
      // Track the next orderIndex for newly queued items
      int nextOrder = (await _dbHelper.getMaxOrderForPlaylist(targetPlaylistId) ?? -1) + 1;

      final existingPlaylistSongs = await _dbHelper.getSongsForPlaylist(targetPlaylistId);
      final existingPlaylistIds = existingPlaylistSongs.map((s) => s.id).toSet();
      final allSongs = await _dbHelper.getSongs();
      final allSongsMap = {for (var s in allSongs) s.id: s};

      for (final track in tracks) {
        final spotifyTrackId = _getSpotifyTrackId(track);

        // Check duplicate in playlist
        final alreadyInPlaylist = existingPlaylistIds.contains(spotifyTrackId);
        if (alreadyInPlaylist) continue;

        // Check global duplicate
        final existingSong = allSongsMap[spotifyTrackId];
        if (existingSong != null && File(existingSong.filePath).existsSync()) {
          await _dbHelper.addSongToPlaylist(targetPlaylistId, existingSong.id, nextOrder);
          existingPlaylistIds.add(existingSong.id);
          nextOrder++;
          existingLinkCount++;
          continue;
        }

        // Add to persistent queue with expected order index
        await _dbHelper.addSpotifyToDownloadQueue(
          spotifyTrackId: spotifyTrackId,
          playlistId: targetPlaylistId,
          title: track.title,
          artist: track.artist,
          durationMs: track.durationMs,
          thumbnailUrl: track.thumbnailUrl,
          expectedOrderIndex: nextOrder,
        );
        nextOrder++;
        addedCount++;
      }

      if (existingLinkCount > 0) {
        if (musicProvider != null) {
          final updateCurrent = musicProvider!.currentPlaylistId == targetPlaylistId;
          await musicProvider!.loadSongsForPlaylist(targetPlaylistId, updateCurrent: updateCurrent);
          await musicProvider!.loadPlaylists();
        }

        final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
        if (currentPlayingPlaylistId == targetPlaylistId && audioHandler != null) {
          final songs = await _dbHelper.getSongsForPlaylist(targetPlaylistId);
          final mediaItems = <MediaItem>[];
          for (final song in songs) {
            mediaItems.add(MediaItem(
              id: song.id,
              album: _playlistName(targetPlaylistId),
              title: song.title,
              artist: song.artist,
              duration: Duration(seconds: song.duration),
              artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
              extras: {
                'filePath': song.filePath,
                'artPath': song.artPath,
              },
            ));
          }
          if (mediaItems.isNotEmpty) {
            await audioHandler!.addQueueItems(mediaItems);
          }
        }
      }

      if (addedCount > 0) {
        _sessionTotal += addedCount;
        _statusMessage = 'Añadidas $addedCount pistas a la cola de descarga.';
        notifyListeners();

        processQueue();
      } else {
        _isDownloading = false;
        _statusMessage = 'Todas las pistas ya están en la lista.';
        notifyListeners();
      }
    } catch (e) {
      _isDownloading = false;
      _errorMessage = e.toString();
      _statusMessage = 'Error descargando la lista de Spotify';
      notifyListeners();
    } finally {
      await WakelockPlus.disable();
    }
  }

  /// Background processor loop that processes SQLite queue items in parallel.
  /// Downloads multiple items simultaneously for better efficiency in background.
  /// Limited to _maxConcurrentDownloads with delays between starts to avoid rate limiting.
  Future<void> processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    final sessionId = _downloadSessionId;

    try {
      await WakelockPlus.enable();
      _beginDownloadClock();

      while (true) {
        if (sessionId != _downloadSessionId || _cancelRequested) break;

        // Si ya tenemos el máximo de descargas activas, esperar y reintentar
        if (_activeDownloads.length >= _maxConcurrentDownloads) {
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        // Obtener cola y filtrar los que ya están en proceso
        final queueItems = await _dbHelper.getDownloadQueue();
        if (queueItems.isEmpty) {
          // Si tampoco hay activos, terminamos
          if (_activeDownloads.isEmpty) break;
          // Si hay activos todavía, esperar a que terminen
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        final availableItems = queueItems
            .where((item) => !_activeDownloads.contains(item['id'] as int))
            // Nunca despachar dos items con el mismo videoId a la vez (ver _activeVideoIds).
            .where((item) => !_activeVideoIds.contains(item['videoId'] as String))
            .toList();

        if (availableItems.isEmpty) {
          // Hay items en cola pero todos están activos — esperar
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        // Tomar solo UN item por iteración para llenar slots libres de a uno
        final item = availableItems.first;

        // Espaciado deliberado entre descargas (ver _interDownloadDelay).
        //
        // Se mide desde el DESPACHO anterior, no desde que terminó: lo que
        // YouTube limita es el ritmo de peticiones a InnerTube, y esas se hacen
        // al principio de cada descarga (getSong + getManifest). Medirlo así hace
        // que el espaciado sea exactamente "como máximo una descarga nueva cada
        // N segundos": si la anterior tardó más que N no se espera nada extra, y
        // si fue rápida (medido: 1.0s para 3.3MB) se completa la diferencia. Un
        // sleep fijo después de cada descarga penalizaría las lentas sin
        // necesidad.
        await _awaitDispatchSpacing(sessionId);
        if (sessionId != _downloadSessionId || _cancelRequested) break;

        _lastDispatchAt = DateTime.now();
        // Lanzar sin await para que el loop siga buscando items inmediatamente
        _processQueueItem(item, sessionId).ignore();
        
        // Pequeño delay antes de lanzar el siguiente para evitar rate limiting
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } finally {
      _isProcessingQueue = false;
      if (_activeDownloads.isEmpty) {
        await WakelockPlus.disable();
        _stopDownloadClock();
      }
    }
  }

  /// Momento del último despacho, para el espaciado. `null` = sesión recién
  /// empezada, así que la primera descarga arranca sin esperar.
  DateTime? _lastDispatchAt;

  /// Espera lo que falte para respetar `_interDownloadDelay` desde el despacho
  /// anterior. Sondea la cancelación cada 300ms en vez de dormir del tirón, por
  /// el mismo motivo que `YoutubeService._cancellableDelay`: si no, cancelar
  /// durante la pausa no surtía efecto hasta que la pausa terminara sola.
  Future<void> _awaitDispatchSpacing(String sessionId) async {
    final last = _lastDispatchAt;
    if (last == null || _interDownloadDelay == Duration.zero) return;

    var remaining = _interDownloadDelay - DateTime.now().difference(last);
    if (remaining <= Duration.zero) return;

    print('Espaciando descargas: esperando ${remaining.inMilliseconds}ms');
    const step = Duration(milliseconds: 300);
    while (remaining > Duration.zero) {
      if (sessionId != _downloadSessionId || _cancelRequested) return;
      final sleepFor = remaining < step ? remaining : step;
      await Future.delayed(sleepFor);
      remaining -= sleepFor;
    }
  }

  /// Procesa un item individual de la cola de descarga
  Future<void> _processQueueItem(Map<String, dynamic> item, String sessionId) async {
    final int queueId = item['id'] as int;
    final String videoId = item['videoId'] as String;
    final String playlistId = item['playlistId'] as String;
    final String source = item['source'] as String? ?? 'youtube';

    // Marcar como activo
    _activeDownloads.add(queueId);
    _activeVideoIds.add(videoId);

    try {
      final playlistExists = await _dbHelper.getPlaylistById(playlistId) != null;
      if (!playlistExists) {
        await _dbHelper.removeFromDownloadQueue(queueId);
        return;
      }

      // Si otra descarga concurrente (misma pista, otra playlist) ya la completó
      // mientras esta esperaba su turno en _activeVideoIds, no volver a descargarla:
      // solo enlazarla a esta playlist. Evita dos workers escribiendo al mismo
      // archivo local <musicDir>/<videoId>.<ext> a la vez.
      final existingSong = await _dbHelper.getSongById(videoId);
      if (existingSong != null && File(existingSong.filePath).existsSync()) {
        final alreadyLinked = await _dbHelper.isSongInPlaylist(playlistId, videoId);
        if (!alreadyLinked) {
          final expectedOrderIndex = item['expectedOrderIndex'] as int?;
          final orderIndex = expectedOrderIndex ??
              (await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1) + 1;
          await _dbHelper.addSongToPlaylist(playlistId, existingSong.id, orderIndex);
          if (musicProvider != null) {
            final updateCurrent = musicProvider!.currentPlaylistId == playlistId;
            await musicProvider!.loadSongsForPlaylist(playlistId, updateCurrent: updateCurrent);
            await musicProvider!.loadPlaylists();
          }
        }
        await _dbHelper.removeFromDownloadQueue(queueId);
        return;
      }

      _currentQueueId = queueId;
      const attemptBudget = Duration(minutes: 10);
      // Un solo intento externo. El nivel interno (`downloadVideoWithAudio`) ya
      // reintenta por su cuenta, así que este bucle no añadía reintentos
      // cualitativamente distintos: sólo multiplicaba por 2 el volumen de
      // peticiones contra un muro que se dispara por volumen ACUMULADO por IP
      // (~12-24 manifests, medido en tool/pacing_probe.dart). Con 2 intentos
      // externos una canción fallida emitía ~60 peticiones de manifest, o sea
      // 2-5x el presupuesto entero de la IP: una sola canción mala dejaba la
      // sesión bloqueada para todas las siguientes.
      const maxAttempts = 1;

      bool success = false;
      bool cancelled = false;
      String? lastFailureReason;

      // Este worker pertenece a `sessionId`. Si la sesión avanzó (el usuario
      // canceló, o mandó una descarga nueva y prepareForNewDownloads() bumpeó el
      // contador), este worker es un zombi: puede terminar de morir, pero no
      // puede seguir escribiendo en el estado compartido de la UI, que ya es de
      // otra sesión.
      bool isStale() => sessionId != _downloadSessionId;

      for (int attempt = 0; attempt < maxAttempts && !success; attempt++) {
        if (isStale() || _cancelRequested) {
          cancelled = true;
          break;
        }

        try {
          _isDownloading = true;
          _errorMessage = null;
          
          // Actualizar UI con información de este item específico
          if (source == 'spotify') {
            _currentTitle = item['spotifyTitle'] as String? ?? 'Desconocido';
          } else {
            _currentTitle = item['videoId']; // YouTube videoId
          }
          
          if (attempt == 0) {
            _progress = 0.0;
            _statusMessage = 'Descargando (${_activeDownloads.length} en paralelo)...';
          } else {
            _statusMessage = 'Reintentando (${attempt + 1}/$maxAttempts)...';
          }
          notifyListeners();

          if (source == 'spotify') {
            final String title = item['spotifyTitle'] as String? ?? 'Desconocido';
            final String artist = item['spotifyArtist'] as String? ?? 'Artista';
            final int durationMs = item['spotifyDurationMs'] as int? ?? 180000;
            final String? thumbnailUrl = item['spotifyThumbnailUrl'] as String?;
            final int? expectedOrderIndex = item['expectedOrderIndex'] as int?;

            await _downloadSpotifyDirectly(
              videoId,
              playlistId,
              title,
              artist,
              durationMs,
              thumbnailUrl,
              sessionId: sessionId,
              attempt: attempt,
              expectedOrderIndex: expectedOrderIndex,
            ).timeout(attemptBudget, onTimeout: () {
              throw TimeoutException(
                'Intento ${attempt + 1}: sin completarse en '
                '${_formatDuration(attemptBudget)}',
              );
            });
          } else {
            final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
            final int? expectedOrderIndex = item['expectedOrderIndex'] as int?;
            await _downloadVideoDirectly(
              videoUrl,
              playlistId,
              sessionId: sessionId,
              attempt: attempt,
              expectedOrderIndex: expectedOrderIndex,
            ).timeout(attemptBudget, onTimeout: () {
              throw TimeoutException(
                'Intento ${attempt + 1}: sin completarse en '
                '${_formatDuration(attemptBudget)}',
              );
            });
          }

          success = true;
        } catch (e, stack) {
          // Una cancelación no es un fallo de descarga: no se registra en el log
          // de errores ni se le muestra al usuario como "error". Antes sí, y por
          // eso download_errors.log terminaba lleno de "Descarga cancelada por el
          // usuario" tapando los errores reales de los intentos anteriores.
          if (YoutubeService.isCancellationError(e) || isStale() || _cancelRequested) {
            cancelled = true;
            print('Descarga de $videoId cancelada (sesión $sessionId)');
            break;
          }

          lastFailureReason = e.toString();
          print('Error en descarga (intento ${attempt + 1}): $e');
          await LogService.logError('Download error for video $videoId (attempt ${attempt + 1})', e, stack);

          // Backoff exponencial entre reintentos para evitar rate limiting.
          // +jitter para que workers concurrentes no reintenten en lockstep.
          // Se interrumpe en cuanto se cancela, en vez de dormir el delay completo —
          // si no, este worker sigue reteniendo su lock en _activeVideoIds y un
          // reenvío del mismo video queda bloqueado detrás de él innecesariamente.
          if (attempt < maxAttempts - 1) {
            final baseMs = 3000 * (attempt + 1); // 3s, 6s
            final jitterMs = Random().nextInt((baseMs * 0.3).round());
            var remainingMs = baseMs + jitterMs;
            const stepMs = 300;
            while (remainingMs > 0) {
              if (sessionId != _downloadSessionId || _cancelRequested) break;
              final sleepMs = remainingMs < stepMs ? remainingMs : stepMs;
              await Future.delayed(Duration(milliseconds: sleepMs));
              remainingMs -= sleepMs;
            }
          }
        }
      }

      // Un worker cancelado/obsoleto sale sin tocar nada compartido: no reporta
      // error, no toca la cola (prepareForNewDownloads/cancelAllDownloads ya la
      // limpiaron, y la que hay ahora pertenece a la sesión nueva) y no resetea
      // _isDownloading. Ese último punto era el síntoma visible: al morir, un
      // zombi entraba por la rama de fallo, ponía "Error en descarga después de 2
      // intentos" y _isDownloading = false sobre una sesión recién arrancada, así
      // que la descarga nueva se veía muerta antes de empezar.
      if (cancelled || isStale()) {
        return;
      }

      if (success) {
        await _dbHelper.removeFromDownloadQueue(queueId);
        _sessionCompleted++;
        _updateProgress();

        // Si no hay más descargas activas, limpiar UI
        if (_activeDownloads.length <= 1) {
          _isDownloading = false;
          _currentTitle = '';
          _progress = 0.0;
          _statusMessage = 'Descarga completada';
        } else {
          _statusMessage = 'Descargando (${_activeDownloads.length - 1} restantes)...';
        }
        notifyListeners();
      } else {
        // Eliminar de cola después de maxAttempts fallidos
        await _dbHelper.removeFromDownloadQueue(queueId);
        _errorMessage = _friendlyDownloadError(lastFailureReason ?? 'Error desconocido');
        _statusMessage = maxAttempts > 1
            ? 'Error en descarga después de $maxAttempts intentos'
            : 'Error en descarga';

        // Limpiar estado de descarga actual solo si no quedan más descargas activas
        if (_activeDownloads.length <= 1) {
          _isDownloading = false;
          _currentTitle = '';
          _progress = 0.0;
        } else {
          _statusMessage = 'Descargando (${_activeDownloads.length - 1} restantes)...';
        }
        notifyListeners();
      }
    } catch (e, stack) {
      print('Error procesando item de cola: $e');
      await LogService.logError('Outer queue item processing error', e, stack);
      await _dbHelper.removeFromDownloadQueue(queueId);
    } finally {
      _activeDownloads.remove(queueId);
      _activeVideoIds.remove(videoId);
      if (_currentQueueId == queueId) _currentQueueId = null;

      // Liberar el wake lock solo si además ya no queda despachador activo: un
      // worker zombi de la sesión anterior puede terminar justo después de que
      // arrancó la sesión nueva y, viendo _activeDownloads vacío por un instante,
      // apagaba el wake lock que esa sesión nueva acababa de pedir.
      if (_activeDownloads.isEmpty && !_isProcessingQueue) {
        await WakelockPlus.disable();
      }
    }
  }

  /// Downloads a single video directly (called by the queue processor).
  Future<void> _downloadVideoDirectly(
    String url,
    String playlistId, {
    required String sessionId,
    int attempt = 0,
    int? expectedOrderIndex,
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

      // Try to fetch and cache lyrics in background during download
      try {
        await LyricsService.instance.getLyrics(
          songId: song.id,
          title: song.title,
          artist: song.artist,
          durationSeconds: song.duration,
        );
      } catch (e) {
        print('Error pre-fetching lyrics during download: $e');
      }

      // 6. Append track to the target playlist (only if not already in playlist)
      final songInPlaylist = await _dbHelper.isSongInPlaylist(playlistId, song.id);
      if (!songInPlaylist) {
        // Use the pre-assigned order index to preserve playlist order,
        // falling back to appending at the end if not set.
        final orderIndex = expectedOrderIndex ?? 
            (await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1) + 1;
        await _dbHelper.addSongToPlaylist(playlistId, song.id, orderIndex);
      }

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
        // Only update current playlist if user is viewing it
        final updateCurrent = musicProvider!.currentPlaylistId == playlistId;
        await musicProvider!.loadSongsForPlaylist(playlistId, updateCurrent: updateCurrent);
        await musicProvider!.loadPlaylists();
      }

      // Dynamic update to active player queue if the same playlist is currently playing
      final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
      if (currentPlayingPlaylistId == playlistId && audioHandler != null && !songInPlaylist) {
        final playlist = musicProvider?.playlists.where((p) => p.id == playlistId).firstOrNull;
        if (playlist != null) {
          final mediaItem = MediaItem(
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
          );
          await audioHandler!.addQueueItem(mediaItem);
        }
      }

      await _showCompletionNotification(title, true);
    } catch (e) {
      await _showCompletionNotification(_currentTitle.isNotEmpty ? _currentTitle : 'Audio', false);
      rethrow;
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<void> _downloadSpotifyDirectly(
    String spotifyTrackId,
    String playlistId,
    String title,
    String artist,
    int durationMs,
    String? spotifyThumbnailUrl, {
    required String sessionId,
    int attempt = 0,
    int? expectedOrderIndex,
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
        _statusMessage = 'Buscando en YouTube...';
      }
      notifyListeners();

      final result = await _youtubeService.searchAndDownload(
        title: title,
        artist: artist,
        expectedDurationMs: durationMs,
        spotifyThumbnailUrl: spotifyThumbnailUrl,
        onMetadata: (resolvedTitle) {
          _currentTitle = resolvedTitle;
          _statusMessage = _sessionTotal > 0
              ? 'Descargando ${_sessionCompleted + 1} de $_sessionTotal: $resolvedTitle'
              : 'Descargando: $resolvedTitle';
          notifyListeners();
          _showProgressNotification(resolvedTitle, 0);
        },
        onPhase: (phase) {
          switch (phase) {
            case 'metadata':
              _statusMessage = 'Buscando canción...';
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

      final format = result['format'] as String;
      final localAudioPath = result['filePath'] as String;
      final localThumbnailPath = result['artPath'] as String;

      _statusMessage = 'Guardando carátula...';
      notifyListeners();

      if (sessionId != _downloadSessionId) {
        throw Exception('Download cancelled');
      }

      final song = Song(
        id: spotifyTrackId,
        title: title,
        artist: artist,
        duration: (durationMs / 1000).round(),
        filePath: localAudioPath,
        artPath: localThumbnailPath,
        format: format,
        downloadDate: DateTime.now(),
      );

      await _dbHelper.insertSong(song);

      try {
        await LyricsService.instance.getLyrics(
          songId: song.id,
          title: song.title,
          artist: song.artist,
          durationSeconds: song.duration,
        );
      } catch (e) {
        print('Error pre-fetching lyrics during download: $e');
      }

      final songInPlaylist = await _dbHelper.isSongInPlaylist(playlistId, song.id);
      if (!songInPlaylist) {
        final orderIndex = expectedOrderIndex ?? 
            (await _dbHelper.getMaxOrderForPlaylist(playlistId) ?? -1) + 1;
        await _dbHelper.addSongToPlaylist(playlistId, song.id, orderIndex);
      }

      if (_sessionTotal > 0) {
        _sessionCompleted++;
      }

      _progress = 1.0;
      _statusMessage = '¡Descarga completada!';
      notifyListeners();

      if (musicProvider != null) {
        final updateCurrent = musicProvider!.currentPlaylistId == playlistId;
        await musicProvider!.loadSongsForPlaylist(playlistId, updateCurrent: updateCurrent);
        await musicProvider!.loadPlaylists();
      }

      final currentPlayingPlaylistId = musicProvider?.currentPlaylistId;
      if (currentPlayingPlaylistId == playlistId && audioHandler != null && !songInPlaylist) {
        final playlist = musicProvider?.playlists.where((p) => p.id == playlistId).firstOrNull;
        if (playlist != null) {
          final mediaItem = MediaItem(
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
          );
          await audioHandler!.addQueueItem(mediaItem);
        }
      }

      await _showCompletionNotification(title, true);
    } catch (e) {
      await _showCompletionNotification(_currentTitle.isNotEmpty ? _currentTitle : title, false);
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
    // El mensaje del muro ya viene redactado para el usuario desde
    // YoutubeService; el truncado genérico de abajo lo partía por la mitad.
    if (e.toString().contains(YoutubeService.botWallMessage)) {
      return YoutubeService.botWallMessage;
    }
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
