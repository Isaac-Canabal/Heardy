import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../services/audio_player_handler.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final audioHandler = Provider.of<AudioPlayerHandler>(context);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 30, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Reproduciendo',
          style: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 1.1),
        ),
        centerTitle: true,
      ),
      body: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, mediaSnapshot) {
          final mediaItem = mediaSnapshot.data;
          if (mediaItem == null) {
            return const Center(
              child: Text(
                'No hay música seleccionada',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }

          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF121212),
                  Color(0xFF1E1E1E), // subtle fade
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 1. Prominent floating Album Cover
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0),
                    child: Card(
                      elevation: 12,
                      shadowColor: const Color(0xFF1A237E).withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: _buildAlbumArt(mediaItem),
                      ),
                    ),
                  ),

                  // 2. Track information
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      children: [
                        Text(
                          mediaItem.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          mediaItem.artist ?? 'Artista desconocido',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 3. Stateful Seek Bar with elapsed and remaining timestamps
                  StreamBuilder<Duration>(
                    stream: audioHandler.player.positionStream,
                    builder: (context, posSnapshot) {
                      final position = posSnapshot.data ?? Duration.zero;
                      final duration = mediaItem.duration ?? Duration.zero;

                      return SeekBar(
                        position: position,
                        duration: duration,
                        onChangeEnd: (newPosition) {
                          audioHandler.seek(newPosition);
                        },
                      );
                    },
                  ),

                  // 4. Playback Controller Buttons
                  StreamBuilder<PlaybackState>(
                    stream: audioHandler.playbackState,
                    builder: (context, stateSnapshot) {
                      final state = stateSnapshot.data;
                      final playing = state?.playing ?? false;
                      final isShuffle = state?.shuffleMode == AudioServiceShuffleMode.all;
                      final repeatMode = state?.repeatMode ?? AudioServiceRepeatMode.none;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Shuffle toggle
                            IconButton(
                              icon: Icon(
                                Icons.shuffle,
                                color: isShuffle ? const Color(0xFF8C9EFF) : Colors.white38,
                                size: 24,
                              ),
                              onPressed: () {
                                audioHandler.setShuffleMode(
                                  isShuffle
                                      ? AudioServiceShuffleMode.none
                                      : AudioServiceShuffleMode.all,
                                );
                              },
                            ),
                            // Skip previous
                            IconButton(
                              icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
                              onPressed: () => audioHandler.skipToPrevious(),
                            ),
                            // Play / Pause central bubble
                            Container(
                              width: 68,
                              height: 68,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                              child: IconButton(
                                icon: Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  color: Colors.black,
                                  size: 36,
                                ),
                                onPressed: () {
                                  if (playing) {
                                    audioHandler.pause();
                                  } else {
                                    audioHandler.play();
                                  }
                                },
                              ),
                            ),
                            // Skip next
                            IconButton(
                              icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
                              onPressed: () => audioHandler.skipToNext(),
                            ),
                            // Repeat toggle
                            _buildRepeatButton(audioHandler, repeatMode),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRepeatButton(AudioPlayerHandler audioHandler, AudioServiceRepeatMode mode) {
    IconData icon = Icons.repeat;
    Color color = Colors.white38;

    if (mode == AudioServiceRepeatMode.one) {
      icon = Icons.repeat_one;
      color = const Color(0xFF8C9EFF);
    } else if (mode == AudioServiceRepeatMode.all) {
      icon = Icons.repeat;
      color = const Color(0xFF8C9EFF);
    }

    return IconButton(
      icon: Icon(icon, color: color, size: 24),
      onPressed: () {
        if (mode == AudioServiceRepeatMode.none) {
          audioHandler.setRepeatMode(AudioServiceRepeatMode.all);
        } else if (mode == AudioServiceRepeatMode.all) {
          audioHandler.setRepeatMode(AudioServiceRepeatMode.one);
        } else {
          audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
        }
      },
    );
  }

  Widget _buildAlbumArt(MediaItem item) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    if (artPath.isNotEmpty) {
      final file = File(artPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: 300,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
        );
      }
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: double.infinity,
      height: 300,
      color: const Color(0xFF1A237E),
      child: const Icon(
        Icons.music_note,
        color: Colors.white70,
        size: 96,
      ),
    );
  }
}

class SeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChangeEnd;

  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onChangeEnd,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.position.inMilliseconds.toDouble();
    final max = widget.duration.inMilliseconds.toDouble();

    return Column(
      children: [
        Slider(
          value: value.clamp(0.0, max),
          max: max > 0 ? max : 1.0,
          activeColor: const Color(0xFF8C9EFF),
          inactiveColor: Colors.white10,
          onChanged: (val) {
            setState(() {
              _dragValue = val;
            });
          },
          onChangeEnd: (val) {
            widget.onChangeEnd(Duration(milliseconds: val.toInt()));
            setState(() {
              _dragValue = null;
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(widget.position),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Text(
                _formatDuration(widget.duration),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
