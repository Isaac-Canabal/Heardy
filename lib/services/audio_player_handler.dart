import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:saf_util/saf_util.dart';
import 'database_helper.dart';
import 'playback_state_service.dart';

final FlutterLocalNotificationsPlugin _errorNotification = FlutterLocalNotificationsPlugin();
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final SafUtil _safUtil = SafUtil();

  // Store the last emitted PlaybackEvent so we can rebuild state on shuffle/loop changes
  PlaybackEvent _lastEvent = PlaybackEvent();

  String? _trackingSongId;
  MediaItem? _trackingMediaItem;
  Duration _trackingMaxPosition = Duration.zero;
  bool _hasRecordedCurrentTrack = false;

  AudioPlayer get player => _player;

  // --- SLEEP TIMER ---
  // In-memory only, by design: a sleep timer that survives a full app kill
  // and fires the next time the app is opened would be a bug, not a feature.
  static const Duration _sleepFadeDuration = Duration(seconds: 6);
  Timer? _sleepFireTimer;
  Timer? _sleepFadeTicker;
  Timer? _sleepTickTimer;
  DateTime? _sleepEndTime;
  bool _sleepFading = false;
  bool _pausingFromSleepFade = false;
  final StreamController<Duration?> _sleepTimerController =
      StreamController<Duration?>.broadcast();

  /// Emits the remaining time on every tick, and `null` when no timer is active.
  Stream<Duration?> get sleepTimerStream => _sleepTimerController.stream;

  /// Synchronous snapshot, for `initialData` on a StreamBuilder.
  Duration? get sleepTimerRemainingNow {
    if (_sleepEndTime == null) return null;
    final remaining = _sleepEndTime!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isSleepTimerActive => _sleepEndTime != null;

  void startSleepTimer(Duration duration) {
    _cleanupSleepTimerOnly();
    _sleepEndTime = DateTime.now().add(duration);
    final fadeStart = duration - _sleepFadeDuration;
    _sleepFireTimer = Timer(
      fadeStart.isNegative ? Duration.zero : fadeStart,
      _beginSleepFade,
    );
    _sleepTickTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _emitSleepRemaining(),
    );
    _emitSleepRemaining();
  }

  /// User-initiated cancel. If a fade-out is mid-flight, restores volume and
  /// keeps the song playing (case: cancel during fade-out).
  Future<void> cancelSleepTimer() async {
    if (_sleepEndTime == null) return;
    if (_sleepFading) {
      await _abortSleepFadeAndCleanup();
    } else {
      _cleanupSleepTimerOnly();
    }
  }

  void _emitSleepRemaining() {
    _sleepTimerController.add(sleepTimerRemainingNow);
  }

  Future<void> _beginSleepFade() async {
    if (_sleepEndTime == null) return; // cancelled before firing
    if (!_player.playing) {
      // Timer fired but the user had already paused manually: nothing to fade,
      // just clear the (now pointless) timer state.
      _cleanupSleepTimerOnly();
      return;
    }

    _sleepFading = true;
    const steps = 30;
    final stepDuration = Duration(
      milliseconds: _sleepFadeDuration.inMilliseconds ~/ steps,
    );
    var stepsLeft = steps;

    _sleepFadeTicker = Timer.periodic(stepDuration, (timer) async {
      stepsLeft--;
      try {
        await _player.setVolume((stepsLeft / steps).clamp(0.0, 1.0));
      } catch (e) {
        print('Error ajustando volumen durante fade-out: $e');
      }
      if (stepsLeft <= 0) {
        timer.cancel();
        await _finishSleepFade();
      }
    });
  }

  /// Natural end of the fade-out: pauses playback, then always restores
  /// volume to 1.0 in a `finally` — if `pause()` throws, the app must not be
  /// left silently muted.
  Future<void> _finishSleepFade() async {
    _pausingFromSleepFade = true;
    try {
      await pause();
    } finally {
      _pausingFromSleepFade = false;
      try {
        await _player.setVolume(1.0);
      } catch (e) {
        print('Error restaurando volumen tras el fade-out: $e');
      } finally {
        _cleanupSleepTimerOnly();
      }
    }
  }

  /// Aborts an in-progress fade (manual pause or explicit cancel mid fade-out)
  /// and restores volume in a `finally` so a half-finished fade can never
  /// leave the app muted.
  Future<void> _abortSleepFadeAndCleanup() async {
    _sleepFadeTicker?.cancel();
    _sleepFadeTicker = null;
    _sleepFading = false;
    try {
      await _player.setVolume(1.0);
    } catch (e) {
      print('Error restaurando volumen al abortar fade-out: $e');
    } finally {
      _cleanupSleepTimerOnly();
    }
  }

  void _cleanupSleepTimerOnly() {
    _sleepFireTimer?.cancel();
    _sleepFadeTicker?.cancel();
    _sleepTickTimer?.cancel();
    _sleepFireTimer = null;
    _sleepFadeTicker = null;
    _sleepTickTimer = null;
    _sleepEndTime = null;
    _sleepFading = false;
    _sleepTimerController.add(null);
  }

  AudioPlayerHandler() {
    _initAudioSession();
    // Intentar restaurar estado guardado al iniciar
    _restoreSavedState();
    
    // Pipe just_audio events to audio_service's playbackState stream
    _player.playbackEventStream.listen((event) {
      _lastEvent = event;
      _updateTrackingPosition();
      playbackState.add(_buildPlaybackState(event));
      // Guardar estado cuando cambia la reproducción
      _saveCurrentState();
    }, onError: (Object e, StackTrace stackTrace) {
      print('A stream error occurred: $e');
      _errorNotification.show(
        999,
        'Error de Reproducción',
        e.toString(),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'com.heardy.app.audio.errors',
            'Errores de Reproducción',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    });

    // Synchronize mediaItem updates when active track index changes
    _player.currentIndexStream.listen((index) async {
      await _finalizePlay();
      final playlistQueue = queue.value;
      if (index != null && playlistQueue.isNotEmpty && index < playlistQueue.length) {
        mediaItem.add(playlistQueue[index]);
        _startTracking(playlistQueue[index]);
      } else {
        _resetTracking();
      }
    });

    // Force playbackState update when SHUFFLE mode changes (just_audio doesn't emit PlaybackEvent for this)
    _player.shuffleModeEnabledStream.listen((_) {
      playbackState.add(_buildPlaybackState(_lastEvent));
    });

    // Force playbackState update when LOOP/REPEAT mode changes
    _player.loopModeStream.listen((_) {
      playbackState.add(_buildPlaybackState(_lastEvent));
    });

    // Monitor track completion to trigger automatic next track
    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        final duration = _trackingMediaItem?.duration ?? _player.duration;
        if (duration != null && duration > Duration.zero) {
          _trackingMaxPosition = duration;
        }
        await _finalizePlay();

        // LoopMode.one is handled internally by just_audio (it repeats automatically).
        // LoopMode.all: wrap around to first track after the last one.
        // LoopMode.off: stop naturally at end.
        if (_player.loopMode == LoopMode.all) {
          if (_player.hasNext) {
            skipToNext();
          } else {
            // Last song in playlist → wrap to first
            _player.seek(Duration.zero, index: 0).then((_) => _player.play());
          }
        } else if (_player.loopMode == LoopMode.off) {
          if (_player.hasNext) {
            skipToNext();
          } else {
            // Stop at end of playlist
            stop();
          }
        }
      }
    });
  }

  /// Builds a PlaybackState from a PlaybackEvent, reading the current player properties.
  PlaybackState _buildPlaybackState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setShuffleMode,
        MediaAction.setRepeatMode,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState] ??
          AudioProcessingState.idle,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      repeatMode: const {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[_player.loopMode] ??
          AudioServiceRepeatMode.none,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
  }

  // --- AUDIO SERVICE CALLBACK OVERRIDES ---

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    if (_sleepFading && !_pausingFromSleepFade) {
      // Manual pause mid fade-out: abort the fade and restore volume so the
      // app isn't left silently muted, but let the pause the user asked for
      // go through normally.
      await _abortSleepFadeAndCleanup();
    }
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _finalizePlay();
    await _player.stop();
    _resetTracking();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> seekRelative(Duration offset) async {
    final duration = _player.duration ?? Duration.zero;
    var newPosition = _player.position + offset;
    if (newPosition < Duration.zero) newPosition = Duration.zero;
    if (duration > Duration.zero && newPosition > duration) {
      newPosition = duration;
    }
    await seek(newPosition);
  }

  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    } else if (_player.loopMode == LoopMode.all && queue.value.isNotEmpty) {
      // Wrap to first track
      await _player.seek(Duration.zero, index: 0);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // If more than 3 seconds in, restart current track instead of going back
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < queue.value.length) {
      await _player.seek(Duration.zero, index: index);
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final index = queue.value.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      await skipToQueueItem(index);
      await _player.play();
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _player.setShuffleModeEnabled(enabled);
    // shuffleModeEnabledStream listener will update playbackState
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    LoopMode mode;
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
      case AudioServiceRepeatMode.group:
        mode = LoopMode.off;
        break;
      case AudioServiceRepeatMode.one:
        mode = LoopMode.one;
        break;
      case AudioServiceRepeatMode.all:
        mode = LoopMode.all;
        break;
    }
    await _player.setLoopMode(mode);
    // loopModeStream listener will update playbackState
  }

  bool _isSafUri(String pathOrUri) => pathOrUri.contains('://');

  /// True if [pathOrUri] can actually be handed to just_audio right now.
  /// Legacy downloads are plain filesystem paths (`File.existsSync`, cheap
  /// and synchronous). SAF-imported songs are `content://` uris — those
  /// can't be checked with `File`, so this asks the SAF provider directly
  /// via a metadata-only query (`SafUtil.exists`, no bytes read). If the
  /// user has revoked the folder permission (or unmounted the volume, or
  /// the provider is otherwise gone), that query throws rather than
  /// returning false — caught here and treated the same as "not playable",
  /// so a revoked permission skips the song instead of crashing playback.
  Future<bool> _isPlayable(String pathOrUri) async {
    if (pathOrUri.isEmpty) return false;
    if (_isSafUri(pathOrUri)) {
      try {
        return await _safUtil.exists(pathOrUri, false);
      } catch (e) {
        print('Uri SAF no verificable (¿permiso revocado?) $pathOrUri: $e');
        return false;
      }
    }
    return File(pathOrUri).existsSync();
  }

  Uri _sourceUriFor(String pathOrUri) =>
      _isSafUri(pathOrUri) ? Uri.parse(pathOrUri) : Uri.file(pathOrUri);

  /// Runs [_isPlayable] over every item in parallel — these are local
  /// existence checks (filesystem or SAF), not network calls, so there's no
  /// concurrency concern like the download engine's circuit breaker.
  Future<List<MediaItem>> _filterPlayable(List<MediaItem> items) async {
    final flags = await Future.wait(items.map(
      (item) => _isPlayable(item.extras?['filePath'] as String? ?? ''),
    ));
    return [
      for (var i = 0; i < items.length; i++)
        if (flags[i]) items[i],
    ];
  }

  ConcatenatingAudioSource? _playlistSource;

  /// Sets the queue, initial index, and starts playing.
  Future<void> playPlaylist(List<MediaItem> items, String targetMediaId) async {
    // Filter out items whose file/uri isn't actually reachable right now,
    // to prevent loading failures (works for both legacy paths and SAF uris).
    final validItems = await _filterPlayable(items);

    if (validItems.isEmpty) return;

    final targetIndex = validItems.indexWhere((item) => item.id == targetMediaId);
    final initialIndex = targetIndex != -1 ? targetIndex : 0;

    // Check if the current queue is exactly the same
    bool isSameQueue = false;
    final currentQueue = queue.value;
    if (currentQueue.length == validItems.length) {
      isSameQueue = true;
      for (int i = 0; i < currentQueue.length; i++) {
        if (currentQueue[i].id != validItems[i].id) {
          isSameQueue = false;
          break;
        }
      }
    }

    if (isSameQueue) {
      // Just seek and play if it's the same playlist
      if (_player.currentIndex != initialIndex) {
        await skipToQueueItem(initialIndex);
      }
      _startTracking(validItems[initialIndex]);
      if (!_player.playing) {
        await _player.play();
      }
      return;
    }

    queue.add(validItems);

    final sources = validItems.map((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return AudioSource.uri(_sourceUriFor(path), tag: item);
    }).toList();

    _playlistSource = ConcatenatingAudioSource(children: sources);

    // Pass initial index to avoid the need to seek immediately after setAudioSource
    await _player.setAudioSource(
      _playlistSource!,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    mediaItem.add(validItems[initialIndex]);
    _startTracking(validItems[initialIndex]);
    await _player.play();
  }

  /// Loads a playlist and seeks to a position WITHOUT auto-playing.
  /// Used to restore a paused state on app restart.
  Future<void> restorePlaylist(
    List<MediaItem> items,
    String targetMediaId,
    Duration position,
  ) async {
    final validItems = await _filterPlayable(items);

    if (validItems.isEmpty) return;

    final targetIndex = validItems.indexWhere((item) => item.id == targetMediaId);
    final initialIndex = targetIndex != -1 ? targetIndex : 0;

    queue.add(validItems);

    final sources = validItems.map((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return AudioSource.uri(_sourceUriFor(path), tag: item);
    }).toList();

    _playlistSource = ConcatenatingAudioSource(children: sources);

    await _player.setAudioSource(
      _playlistSource!,
      initialIndex: initialIndex,
      initialPosition: position,
    );

    mediaItem.add(validItems[initialIndex]);
    _startTracking(validItems[initialIndex]);
    // Do NOT call _player.play() — restore paused state
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    try {
      final path = mediaItem.extras?['filePath'] as String? ?? '';
      if (path.isEmpty) {
        print('Error: path vacío para mediaItem ${mediaItem.id}');
        return;
      }

      if (!await _isPlayable(path)) {
        print('Error: archivo/uri no disponible para mediaItem ${mediaItem.id}: $path');
        return;
      }

      final currentQueue = queue.value;
      if (currentQueue.any((item) => item.id == mediaItem.id)) return;

      queue.add([...currentQueue, mediaItem]);

      if (_playlistSource != null) {
        try {
          await _playlistSource!.add(AudioSource.uri(_sourceUriFor(path), tag: mediaItem));
        } on PlatformException catch (e) {
          print('Error PlatformException en addQueueItem: ${e.message}');
          print('Detalles: ${e.details}');
          // Quitar el item de la queue si falló cargar
          queue.add(currentQueue);
        }
      }
    } catch (e) {
      print('Error agregando item a la queue: $e');
    }
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    try {
      final validItems = await _filterPlayable(mediaItems);

      if (validItems.isEmpty) return;

      final currentQueue = queue.value;
      final existingIds = currentQueue.map((i) => i.id).toSet();
      final newItems = validItems.where((item) => !existingIds.contains(item.id)).toList();

      if (newItems.isEmpty) return;

      queue.add([...currentQueue, ...newItems]);

      if (_playlistSource != null) {
        try {
          final sources = newItems.map((item) {
            final path = item.extras!['filePath'] as String;
            return AudioSource.uri(_sourceUriFor(path), tag: item);
          }).toList();
          await _playlistSource!.addAll(sources);
        } on PlatformException catch (e) {
          print('Error PlatformException en addQueueItems: ${e.message}');
          print('Detalles: ${e.details}');
          queue.add(currentQueue);
        }
      }
    } catch (e) {
      print('Error agregando items a la queue: $e');
    }
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final currentQueue = queue.value;
    final index = currentQueue.indexWhere((item) => item.id == mediaItem.id);
    if (index == -1) return;

    final newQueue = List<MediaItem>.from(currentQueue)..removeAt(index);
    queue.add(newQueue);

    if (_playlistSource != null && index < _playlistSource!.length) {
      await _playlistSource!.removeAt(index);
    }
  }

  /// Reorders a queue item at oldIndex to newIndex, updating both the AudioService queue and the just_audio playlist source
  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    final currentQueue = queue.value;
    if (oldIndex < 0 || oldIndex >= currentQueue.length || newIndex < 0 || newIndex > currentQueue.length) return;

    int targetIndex = newIndex;
    if (oldIndex < newIndex) {
      targetIndex = newIndex - 1;
    }

    final newQueue = List<MediaItem>.from(currentQueue);
    final item = newQueue.removeAt(oldIndex);
    newQueue.insert(targetIndex, item);
    queue.add(newQueue);

    if (_playlistSource != null && oldIndex < _playlistSource!.length && targetIndex < _playlistSource!.length) {
      await _playlistSource!.move(oldIndex, targetIndex);
    }
  }

  /// Gracefully terminates background play state when swipe-closing the application.

  @override
  Future<void> onTaskRemoved() async {
    try {
      // `stop()` sí, `dispose()` NO. `_player` es `final` (ver arriba), así que
      // destruirlo es irreversible: no hay forma de recrearlo en este proceso.
      //
      // Aquí había un `dispose()`, y sólo era inocuo si el proceso moría justo
      // después. Pero con `androidNotificationOngoing: true` (main.dart) el
      // servicio está en foreground y el proceso suele sobrevivir a que el
      // usuario deslice la app fuera de recientes — que es exactamente cuando
      // salta este callback. En ese caso reabrir la app daba un reproductor
      // muerto hasta forzar el cierre.
      await _player.stop();
    } catch (e) {
      print("Error stopping player on task remove: $e");
    }
    // Igual que fullRepair(): sin esto, si el proceso sobrevive al swipe (caso de
    // arriba), `queue`/`mediaItem` quedan apuntando a una fuente que el player ya
    // liberó — la UI muestra la última canción como si nada, pero play() actúa
    // sobre un reproductor sin fuente cargada. hasLoadedSource (ver abajo) detecta
    // y corrige esto igual si el proceso muere del todo y este callback ni corre.
    _playlistSource = null;
    queue.add([]);
    mediaItem.add(null);
    await super.onTaskRemoved();
  }

  /// True si hay una fuente realmente cargada en el player, no solo metadata en
  /// `queue`/`mediaItem`. Lo usa `MusicProvider.restorePlaybackState` para saber
  /// si hace falta restaurar algo, en vez de un guard de "ya corrí una vez".
  bool get hasLoadedSource =>
      _playlistSource != null &&
      queue.value.isNotEmpty &&
      mediaItem.value != null &&
      _player.processingState != ProcessingState.idle;

  /// Resets the player state if it gets corrupted. Call this if playback stops working.
  Future<void> resetPlayerState() async {
    try {
      print('Resetting player state...');
      await _player.stop();
      _playlistSource = null;
      queue.add([]);
      mediaItem.add(null);
      await Future.delayed(const Duration(milliseconds: 200));
      // Limpiar estado guardado al resetear
      await PlaybackStateService.clearState();
      print('Player state reset complete');
    } catch (e) {
      print('Error resetting player state: $e');
    }
  }

  /// Reproduce una URL directamente (para streaming temporal)
  Future<void> playUrl(String url, MediaItem item) async {
    try {
      _resetTracking();
      // Resetear el reproductor antes de cargar nueva URL
      await _player.stop();
      
      // Cargar la URL con timeout
      await _player.setUrl(url).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout cargando URL de audio');
        },
      );
      
      mediaItem.add(item);
      playbackState.add(_buildPlaybackState(
        PlaybackEvent(
          processingState: ProcessingState.ready,
          updateTime: DateTime.now(),
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          duration: item.duration,
          currentIndex: 0,
        ),
      ));
      await _player.play();
    } on PlatformException catch (e) {
      print('Error de plataforma reproduciendo URL: ${e.message}');
      print('Detalles: ${e.details}');
      throw Exception('Error al cargar audio: ${e.message}');
    } catch (e) {
      print('Error reproduciendo URL directa: $e');
      rethrow;
    }
  }

  /// Reparación completa del reproductor para problemas de corrupción
  Future<String> fullRepair() async {
    try {
      print('Iniciando reparación completa...');
      
      // 1. Detener y limpiar el reproductor completamente
      await _player.stop();
      
      // 2. Limpiar estados
      _playlistSource = null;
      queue.add([]);
      mediaItem.add(null);
      
      // 3. Esperar para asegurar liberación de recursos
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 4. Limpiar cualquier cache interno
      try {
        // Limpiar buffer de audio forzando speed reset
        await _player.setSpeed(1.0);
        // Seek al inicio para limpiar buffer
        await _player.seek(Duration.zero);
      } catch (e) {
        print('Error limpiando buffer: $e');
      }
      
      print('Reparación completa finalizada');
      return 'Reparación completada exitosamente';
    } catch (e) {
      print('Error en reparación completa: $e');
      return 'Error durante la reparación: $e';
    }
  }

  void _startTracking(MediaItem item) {
    final filePath = item.extras?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      _resetTracking();
      return;
    }

    _trackingSongId = item.id;
    _trackingMediaItem = item;
    _trackingMaxPosition = Duration.zero;
    _hasRecordedCurrentTrack = false;
  }

  void _resetTracking() {
    _trackingSongId = null;
    _trackingMediaItem = null;
    _trackingMaxPosition = Duration.zero;
    _hasRecordedCurrentTrack = false;
  }

  void _updateTrackingPosition() {
    if (_trackingSongId == null || _hasRecordedCurrentTrack) return;
    if (mediaItem.value?.id != _trackingSongId) return;

    final position = _player.position;
    if (position > _trackingMaxPosition) {
      _trackingMaxPosition = position;
    }
  }

  Future<void> _finalizePlay() async {
    if (_hasRecordedCurrentTrack ||
        _trackingSongId == null ||
        _trackingMediaItem == null) {
      return;
    }

    final filePath = _trackingMediaItem!.extras?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty || !await _isPlayable(filePath)) {
      return;
    }

    final duration = _trackingMediaItem!.duration ??
        _player.duration ??
        Duration.zero;
    if (duration.inSeconds <= 0) return;

    final listenedSeconds = _trackingMaxPosition.inSeconds;
    final threshold = (duration.inSeconds * 0.5).ceil();

    if (listenedSeconds >= threshold) {
      try {
        await DatabaseHelper.instance.recordPlay(
          _trackingSongId!,
          listenedSeconds,
        );
        _hasRecordedCurrentTrack = true;
      } catch (e) {
        print('Error registrando reproducción: $e');
      }
    }
  }

  /// Guarda el estado actual de reproducción
  Future<void> _saveCurrentState() async {
    try {
      final mediaItemValue = mediaItem.value;
      final queueValue = queue.value;
      
      if (mediaItemValue == null || queueValue.isEmpty) {
        return;
      }
      
      await PlaybackStateService.saveState(
        isPlaying: _player.playing,
        currentMediaId: mediaItemValue.id,
        position: _player.position,
        queue: queueValue,
        shuffleMode: playbackState.value.shuffleMode,
        loopMode: playbackState.value.repeatMode,
        speed: _player.speed,
        playlistId: mediaItemValue.extras?['playlist_id'] as String?,
      );
    } catch (e) {
      print('Error guardando estado actual: $e');
    }
  }

  /// Restaura el estado guardado de reproducción
  Future<void> _restoreSavedState() async {
    try {
      final savedState = await PlaybackStateService.restoreState();
      if (savedState == null) {
        print('No hay estado guardado para restaurar');
        return;
      }
      
      // Notificar que estamos restaurando
      print('Estado guardado detectado, esperando a MusicProvider para restauración...');
      
      // La restauración real se hará en MusicProvider después de cargar las playlists
      // Aquí solo verificamos que haya estado guardado
    } catch (e) {
      print('Error restaurando estado guardado: $e');
    }
  }

  /// Inicializa la sesión de audio para el manejo de foco de audio del SO
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      print('Sesión de audio inicializada exitosamente.');
    } catch (e) {
      print('Error inicializando la sesión de audio: $e');
    }
  }
}
