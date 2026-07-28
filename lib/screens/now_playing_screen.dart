import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:palette_generator/palette_generator.dart';
import '../services/audio_player_handler.dart';
import '../services/lyrics_service.dart';
import '../services/audio_analysis_service.dart';

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  MediaItem? _currentMediaItem;
  Color _dominantColor = const Color(0xFF1E1E1E);

  void _updatePalette(MediaItem? item) async {
    if (item == null) return;
    final artPath = item.extras?['artPath'] as String? ?? '';
    if (artPath.isEmpty) {
      if (mounted) {
        setState(() {
          _dominantColor = const Color(0xFF1E1E1E);
        });
      }
      return;
    }

    final file = File(artPath);
    if (!file.existsSync()) {
      if (mounted) {
        setState(() {
          _dominantColor = const Color(0xFF1E1E1E);
        });
      }
      return;
    }

    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        FileImage(file),
        maximumColorCount: 12,
      );

      final extractedColor = paletteGenerator.dominantColor?.color ??
          paletteGenerator.darkMutedColor?.color ??
          paletteGenerator.darkVibrantColor?.color ??
          const Color(0xFF1E1E1E);

      if (mounted) {
        setState(() {
          _dominantColor = extractedColor;
        });
      }
    } catch (e) {
      print('Error extracting dominant color: $e');
      if (mounted) {
        setState(() {
          _dominantColor = const Color(0xFF1E1E1E);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final audioHandler = Provider.of<AudioPlayerHandler>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
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

          if (_currentMediaItem?.id != mediaItem.id) {
            _currentMediaItem = mediaItem;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _updatePalette(mediaItem);
            });
          }

          return AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _dominantColor.withValues(alpha: 0.4),
                  const Color(0xFF0D0D0D),
                ],
                stops: const [0.0, 0.85],
              ),
            ),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 1. Prominent album cover
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0),
                    child: Card(
                      elevation: 16,
                      shadowColor: _dominantColor.withValues(alpha: 0.3),
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

                  // 3. Quick Action Buttons
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.lyrics_outlined, size: 18, color: Colors.white),
                          label: const Text('Letra', style: TextStyle(color: Colors.white, fontSize: 13)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.08),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          ),
                          onPressed: () => _showLyricsBottomSheet(context, audioHandler, mediaItem),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.queue_music, size: 18, color: Colors.white),
                          label: const Text('Cola', style: TextStyle(color: Colors.white, fontSize: 13)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.08),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          ),
                          onPressed: () => _showQueueBottomSheet(context, audioHandler),
                        ),
                      ],
                    ),
                  ),

                  // 4. Seek Bar
                  StreamBuilder<Duration>(
                    stream: audioHandler.player.positionStream,
                    builder: (context, posSnapshot) {
                      final position = posSnapshot.data ?? Duration.zero;
                      final duration = mediaItem.duration ?? Duration.zero;

                      return WaveformSeekBar(
                        position: position,
                        duration: duration,
                        songId: mediaItem.id,
                        filePath: mediaItem.extras?['filePath'] as String?,
                        onChangeEnd: (newPosition) {
                          audioHandler.seek(newPosition);
                        },
                      );
                    },
                  ),

                  // 5. Central Playback Controls
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
                            IconButton(
                              icon: const Icon(Icons.replay_5, color: Colors.white70, size: 26),
                              tooltip: 'Retroceder 5 s',
                              onPressed: () => audioHandler.seekRelative(
                                const Duration(seconds: -5),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
                              onPressed: () => audioHandler.skipToPrevious(),
                            ),
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
                            IconButton(
                              icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
                              onPressed: () => audioHandler.skipToNext(),
                            ),
                            IconButton(
                              icon: const Icon(Icons.forward_5, color: Colors.white70, size: 26),
                              tooltip: 'Adelantar 5 s',
                              onPressed: () => audioHandler.seekRelative(
                                const Duration(seconds: 5),
                              ),
                            ),
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
    return SmartAlbumArt(artPath: artPath, size: 300);
  }

  void _showLyricsBottomSheet(BuildContext context, AudioPlayerHandler audioHandler, MediaItem mediaItem) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return LyricsBottomSheet(mediaItem: mediaItem, audioHandler: audioHandler);
      },
    );
  }

  void _showQueueBottomSheet(BuildContext context, AudioPlayerHandler audioHandler) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return QueueBottomSheet(audioHandler: audioHandler);
      },
    );
  }
}

// --- LYRICS BOTTOM SHEET ---
class LyricsBottomSheet extends StatefulWidget {
  final MediaItem mediaItem;
  final AudioPlayerHandler audioHandler;

  const LyricsBottomSheet({
    super.key,
    required this.mediaItem,
    required this.audioHandler,
  });

  @override
  State<LyricsBottomSheet> createState() => _LyricsBottomSheetState();
}

class _LyricsBottomSheetState extends State<LyricsBottomSheet> {
  bool _isLoading = true;
  String? _lyricsText;
  List<LyricLine> _parsedLines = [];
  int _activeIndex = -1;
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _lyricKeys = [];
  late final Stream<Duration> _positionStream;
  bool _userScrolling = false;
  DateTime _lastScrollTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _positionStream = widget.audioHandler.player.positionStream;
    _fetchLyrics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _fetchLyrics() async {
    try {
      final songId = widget.mediaItem.id;
      final lyrics = await LyricsService.instance.getLyrics(
        songId: songId,
        title: widget.mediaItem.title,
        artist: widget.mediaItem.artist ?? '',
        durationSeconds: widget.mediaItem.duration?.inSeconds ?? 0,
      );

      if (lyrics != null && lyrics.isNotEmpty) {
        final lines = LyricsService.instance.parseLrc(lyrics);
        if (mounted) {
          setState(() {
            _lyricsText = lyrics;
            _parsedLines = lines;
            _lyricKeys.clear();
            _lyricKeys.addAll(List.generate(lines.length, (_) => GlobalKey()));
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _lyricsText = null;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      print('Error fetching lyrics: $e');
      if (mounted) {
        setState(() {
          _lyricsText = null;
          _isLoading = false;
        });
      }
    }
  }

  void _scrollToActiveLine(int index) {
    if (index < 0 || index >= _lyricKeys.length) return;

    if (_userScrolling && DateTime.now().difference(_lastScrollTime).inSeconds < 3) {
      return;
    }

    _userScrolling = false;

    final key = _lyricKeys[index];
    if (key.currentContext != null) {
      Scrollable.ensureVisible(
        key.currentContext!,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isSynced = _parsedLines.isNotEmpty;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        height: media.size.height * 0.85,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.5),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Letra',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF8C9EFF),
                      ),
                    )
                  : _lyricsText == null
                      ? const Center(
                          child: Text(
                            'Letra no disponible',
                            style: TextStyle(color: Colors.white38, fontSize: 16),
                          ),
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is UserScrollNotification) {
                              _userScrolling = true;
                              _lastScrollTime = DateTime.now();
                            }
                            return false;
                          },
                          child: isSynced
                              ? StreamBuilder<Duration>(
                                  stream: _positionStream,
                                  builder: (context, posSnapshot) {
                                    final position = posSnapshot.data ?? Duration.zero;

                                    int newActiveIndex = -1;
                                    for (int i = 0; i < _parsedLines.length; i++) {
                                      final lineTime = _parsedLines[i].time;
                                      final nextLineTime = i < _parsedLines.length - 1
                                          ? _parsedLines[i + 1].time
                                          : const Duration(hours: 1);
                                      if (position >= lineTime && position < nextLineTime) {
                                        newActiveIndex = i;
                                        break;
                                      }
                                    }

                                    if (newActiveIndex != _activeIndex && newActiveIndex != -1) {
                                      _activeIndex = newActiveIndex;
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        _scrollToActiveLine(_activeIndex);
                                      });
                                    }

                                    return ListView.builder(
                                      controller: _scrollController,
                                      itemCount: _parsedLines.length,
                                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                                      itemBuilder: (context, index) {
                                        final line = _parsedLines[index];
                                        final isActive = index == _activeIndex;

                                        return GestureDetector(
                                          key: _lyricKeys[index],
                                          onTap: () {
                                            widget.audioHandler.seek(line.time);
                                            setState(() {
                                              _activeIndex = index;
                                              _userScrolling = false;
                                            });
                                            _scrollToActiveLine(index);
                                          },
                                          child: AnimatedDefaultTextStyle(
                                            duration: const Duration(milliseconds: 200),
                                            style: TextStyle(
                                              color: isActive ? Colors.white : Colors.white38,
                                              fontSize: isActive ? 21 : 18,
                                              fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                                              height: 1.5,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 10.0),
                                              child: Text(
                                                line.text,
                                                textAlign: TextAlign.left,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                )
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.all(24.0),
                                  child: Text(
                                    _lyricsText!,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 18,
                                      height: 1.6,
                                    ),
                                  ),
                                ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- QUEUE / COLA BOTTOM SHEET ---
class QueueBottomSheet extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const QueueBottomSheet({
    super.key,
    required this.audioHandler,
  });

  @override
  State<QueueBottomSheet> createState() => _QueueBottomSheetState();
}

class _QueueBottomSheetState extends State<QueueBottomSheet> {
  String _formatDuration(Duration? d) {
    if (d == null) return '0:00';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        height: media.size.height * 0.85,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.5),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Cola de reproducción',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: StreamBuilder<List<MediaItem>>(
                stream: widget.audioHandler.queue,
                builder: (context, queueSnapshot) {
                  final list = queueSnapshot.data ?? [];
                  if (list.isEmpty) {
                    return const Center(
                      child: Text(
                        'Cola vacía',
                        style: TextStyle(color: Colors.white38, fontSize: 16),
                      ),
                    );
                  }

                  return StreamBuilder<MediaItem?>(
                    stream: widget.audioHandler.mediaItem,
                    builder: (context, mediaSnapshot) {
                      final currentItem = mediaSnapshot.data;

                      return ReorderableListView.builder(
                        itemCount: list.length,
                        onReorder: (oldIndex, newIndex) {
                          widget.audioHandler.moveQueueItem(oldIndex, newIndex);
                        },
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemBuilder: (context, index) {
                          final item = list[index];
                          final isPlaying = currentItem?.id == item.id;

                          return Dismissible(
                            key: ValueKey('dismiss_${item.id}'),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20.0),
                              color: Colors.redAccent.withValues(alpha: 0.8),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (_) {
                              widget.audioHandler.removeQueueItem(item);
                            },
                            child: Material(
                              key: ValueKey('tile_${item.id}'),
                              color: isPlaying ? Colors.white.withValues(alpha: 0.06) : Colors.transparent,
                              child: ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: _buildThumbnail(item),
                                ),
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isPlaying ? const Color(0xFF8C9EFF) : Colors.white,
                                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                                    fontSize: 15,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.artist ?? 'Artista desconocido'} • ${_formatDuration(item.duration)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isPlaying ? const Color(0xFF8C9EFF).withValues(alpha: 0.7) : Colors.white38,
                                    fontSize: 13,
                                  ),
                                ),
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: Icon(Icons.drag_handle, color: Colors.white38),
                                  ),
                                ),
                                onTap: () {
                                  widget.audioHandler.playFromMediaId(item.id);
                                },
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(MediaItem item) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    return SmartAlbumArt(artPath: artPath, size: 48);
  }
}

// --- STATEFUL SEEK BAR ---
class WaveformSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChangeEnd;
  final String? songId;
  final String? filePath;

  const WaveformSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onChangeEnd,
    this.songId,
    this.filePath,
  });

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  double? _dragValue;
  List<double> _barHeights = [];
  static const int barCount = 50;
  static const double barWidth = 4.0;
  static const double barSpacing = 3.0;
  static const double minHeight = 8.0;
  static const double maxHeight = 36.0;

  @override
  void initState() {
    super.initState();
    // Inicializar con alturas temporales mientras carga el análisis real
    _initializeTempHeights();
    _generateWaveform();
  }

  void _initializeTempHeights() {
    _barHeights = List.generate(barCount, (index) {
      return minHeight + ((index % 3) / 3) * (maxHeight - minHeight);
    });
  }

  @override
  void didUpdateWidget(covariant WaveformSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId || oldWidget.filePath != widget.filePath) {
      _generateWaveform();
    }
  }

  Future<void> _generateWaveform() async {
    _barHeights = [];
    
    // Si tenemos ruta del archivo, usar análisis real
    if (widget.filePath != null && widget.filePath!.isNotEmpty) {
      try {
        final amplitudes = await AudioAnalysisService.extractWaveformData(
          widget.filePath!,
          barCount: barCount,
        );
        
        if (mounted) {
          setState(() {
            _barHeights = _mapAmplitudesToHeights(amplitudes);
          });
        }
        return;
      } catch (e) {
        print('Error en análisis de audio real, usando fallback: $e');
      }
    }
    
    // Fallback: usar songId como seed para generar una waveform única pero consistente
    final seed = widget.songId?.hashCode ?? DateTime.now().millisecondsSinceEpoch;
    
    for (int i = 0; i < barCount; i++) {
      // Generar altura basada en el seed y posición para consistencia
      final baseSeed = seed + i * 31;
      final isHighPeak = (baseSeed % 7) < 3; // Patrón más variado
      final baseHeight = isHighPeak ? maxHeight : minHeight;
      
      // Variación más dinámica basada en el seed
      final variation = ((baseSeed * 17) % 12).toDouble();
      final peakFactor = (i % 5 == 0) ? 6.0 : 0.0; // Picos ocasionales
      
      final height = baseHeight - variation + peakFactor;
      _barHeights.add(height.clamp(minHeight, maxHeight));
    }
    
    if (mounted) {
      setState(() {});
    }
  }

  /// Mapea amplitudes (0.0-1.0) a alturas de barras (minHeight-maxHeight)
  List<double> _mapAmplitudesToHeights(List<double> amplitudes) {
    return amplitudes.map((amplitude) {
      // Expandir el rango para más variación visual extrema
      // Usar curva cúbica para aún más diferenciación entre valores
      final expandedAmplitude = amplitude * amplitude * amplitude; // Curva cúbica
      
      // Añadir un poco de aleatoriedad para más variación visual
      final randomFactor = (DateTime.now().millisecondsSinceEpoch % 100) / 1000.0;
      final adjustedAmplitude = (expandedAmplitude + randomFactor).clamp(0.0, 1.0);
      
      final height = minHeight + (adjustedAmplitude * (maxHeight - minHeight));
      return height.clamp(minHeight, maxHeight);
    }).toList();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _handlePanUpdate(DragUpdateDetails details, RenderBox box) {
    final localPosition = box.globalToLocal(details.globalPosition);
    final percentage = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
    setState(() {
      _dragValue = percentage * widget.duration.inMilliseconds;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_dragValue != null) {
      widget.onChangeEnd(Duration(milliseconds: _dragValue!.toInt()));
      setState(() {
        _dragValue = null;
      });
    }
  }

  void _handleTap(TapUpDetails details, RenderBox box) {
    final localPosition = box.globalToLocal(details.globalPosition);
    final percentage = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
    final newValue = percentage * widget.duration.inMilliseconds;
    widget.onChangeEnd(Duration(milliseconds: newValue.toInt()));
  }

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.position.inMilliseconds.toDouble();
    final max = widget.duration.inMilliseconds.toDouble();
    final progress = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;
    final activeBars = (progress * barCount).floor();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                onPanStart: (_) {},
                onPanUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox;
                  _handlePanUpdate(details, box);
                },
                onPanEnd: _handlePanEnd,
                onTapUp: (details) {
                  final box = context.findRenderObject() as RenderBox;
                  _handleTap(details, box);
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: maxHeight + 8,
                  alignment: Alignment.center,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: List.generate(barCount, (index) {
                        final isActive = index < activeBars;
                        final isLastActive = index == activeBars - 1;
                        
                        // Calcular opacidad para la última barra activa
                        final opacity = isLastActive 
                            ? (progress * barCount) - activeBars
                            : 1.0;

                        // Usar altura del análisis o fallback si está vacío
                        final height = _barHeights.isNotEmpty && index < _barHeights.length
                            ? _barHeights[index]
                            : minHeight;

                        return Container(
                          width: barWidth,
                          height: height,
                          margin: EdgeInsets.only(
                            right: index < barCount - 1 ? barSpacing : 0,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(barWidth / 2),
                            color: isActive
                                ? const Color(0xFF8C9EFF).withValues(alpha: opacity.clamp(0.3, 1.0))
                                : Colors.white10,
                          ),
                        );
                      }),
                    ),
                  ),
                ),
              );
            },
          ),
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

// SeekBar original para backwards compatibility si es necesario
class SeekBar extends WaveformSeekBar {
  const SeekBar({
    super.key,
    required super.position,
    required super.duration,
    required super.onChangeEnd,
    super.songId,
    super.filePath,
  });
}

// --- SMART ALBUM ART (DYNAMIC ASPECT CROP) ---
class SmartAlbumArt extends StatefulWidget {
  final String artPath;
  final double size;

  const SmartAlbumArt({
    super.key,
    required this.artPath,
    required this.size,
  });

  @override
  State<SmartAlbumArt> createState() => _SmartAlbumArtState();
}

class _SmartAlbumArtState extends State<SmartAlbumArt> {
  double? _imageAspectRatio;
  bool _hasError = false;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  @override
  void didUpdateWidget(covariant SmartAlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artPath != widget.artPath) {
      _resolveImageSize();
    }
  }

  void _resolveImageSize() {
    if (widget.artPath.isEmpty) {
      setState(() {
        _imageAspectRatio = null;
        _hasError = true;
      });
      return;
    }

    final file = File(widget.artPath);
    if (!file.existsSync()) {
      setState(() {
        _imageAspectRatio = null;
        _hasError = true;
      });
      return;
    }

    // El listener anterior se retira antes de resolver otra imagen. Sin esto,
    // `_resolveImageSize()` —que se llama desde `initState` Y desde
    // `didUpdateWidget`, o sea en cada cambio de carátula— añadía un
    // `ImageStreamListener` más y no quitaba ninguno nunca. El `ImageStream`
    // retiene la closure, y la closure retiene este `State`, así que el objeto no
    // se podía liberar: la memoria crecía a cada canción. No llegaba a petar
    // porque los callbacks comprueban `mounted`, pero la fuga era real.
    _detachImageListener();

    final image = FileImage(file);
    final stream = image.resolve(ImageConfiguration.empty);
    _imageStream = stream;
    _imageListener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          if (mounted) {
            setState(() {
              _imageAspectRatio = info.image.width / info.image.height;
              _hasError = false;
            });
          }
        },
        onError: (exception, stackTrace) {
          if (mounted) {
            setState(() {
              _imageAspectRatio = null;
              _hasError = true;
            });
          }
        },
    );
    stream.addListener(_imageListener!);
  }

  void _detachImageListener() {
    final stream = _imageStream;
    final listener = _imageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageListener = null;
  }

  @override
  void dispose() {
    // Este State no tenía `dispose()` en absoluto.
    _detachImageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError || widget.artPath.isEmpty) {
      return _buildPlaceholder();
    }

    final file = File(widget.artPath);

    if (_imageAspectRatio == null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        width: widget.size,
        height: widget.size,
      );
    }

    // 1. If the image is letterboxed 4:3 (~1.33)
    // We crop 12.5% from top/bottom and 21.875% from sides to isolate the 1:1 square.
    if ((_imageAspectRatio! - 1.333).abs() < 0.05) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            minWidth: widget.size * 1.7778,
            maxWidth: widget.size * 1.7778,
            minHeight: widget.size * 1.3333,
            maxHeight: widget.size * 1.3333,
            child: Image.file(
              file,
              fit: BoxFit.fill,
              width: widget.size * 1.7778,
              height: widget.size * 1.3333,
            ),
          ),
        ),
      );
    }

    // 2. Otherwise (including native 16:9), BoxFit.cover on a square automatically clips side bars perfectly
    return Image.file(
      file,
      fit: BoxFit.cover,
      width: widget.size,
      height: widget.size,
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: widget.size,
      height: widget.size,
      color: const Color(0xFF1A237E),
      child: Icon(
        Icons.music_note,
        color: Colors.white70,
        size: widget.size * 0.5,
      ),
    );
  }
}
