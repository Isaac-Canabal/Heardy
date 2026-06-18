import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin _errorNotification = FlutterLocalNotificationsPlugin();
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  // Store the last emitted PlaybackEvent so we can rebuild state on shuffle/loop changes
  PlaybackEvent _lastEvent = PlaybackEvent();

  AudioPlayer get player => _player;

  AudioPlayerHandler() {
    // Pipe just_audio events to audio_service's playbackState stream
    _player.playbackEventStream.listen((event) {
      _lastEvent = event;
      playbackState.add(_buildPlaybackState(event));
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
    _player.currentIndexStream.listen((index) {
      final playlistQueue = queue.value;
      if (index != null && playlistQueue.isNotEmpty && index < playlistQueue.length) {
        mediaItem.add(playlistQueue[index]);
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
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
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
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

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

  ConcatenatingAudioSource? _playlistSource;

  /// Sets the queue, initial index, and starts playing.
  Future<void> playPlaylist(List<MediaItem> items, String targetMediaId) async {
    // Filter out items without valid local files to prevent loading failures
    final validItems = items.where((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return path.isNotEmpty && File(path).existsSync();
    }).toList();

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
      if (!_player.playing) {
        await _player.play();
      }
      return;
    }

    queue.add(validItems);

    final sources = validItems.map((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return AudioSource.uri(Uri.file(path), tag: item);
    }).toList();

    _playlistSource = ConcatenatingAudioSource(children: sources);
    
    // Pass initial index to avoid the need to seek immediately after setAudioSource
    await _player.setAudioSource(
      _playlistSource!,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    mediaItem.add(validItems[initialIndex]);
    await _player.play();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final path = mediaItem.extras?['filePath'] as String? ?? '';
    if (path.isEmpty || !File(path).existsSync()) return;

    final currentQueue = queue.value;
    if (currentQueue.any((item) => item.id == mediaItem.id)) return;

    queue.add([...currentQueue, mediaItem]);

    if (_playlistSource != null) {
      await _playlistSource!.add(AudioSource.uri(Uri.file(path), tag: mediaItem));
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
      await _player.stop();
      await _player.dispose();
    } catch (e) {
      print("Error disposing player on task remove: $e");
    }
    await super.onTaskRemoved();
  }

  /// Resets the player state if it gets corrupted. Call this if playback stops working.
  Future<void> resetPlayerState() async {
    try {
      print('Resetting player state...');
      await _player.stop();
      _playlistSource = null;
      queue.add([]);
      mediaItem.add(null);
      await Future.delayed(const Duration(milliseconds: 200));
      print('Player state reset complete');
    } catch (e) {
      print('Error resetting player state: $e');
    }
  }
}
