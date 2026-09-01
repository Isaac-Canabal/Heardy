import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:palette_generator/palette_generator.dart';
import '../services/audio_player_handler.dart';
import '../services/lyrics_service.dart';
import '../services/translation_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';

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
      // El slide-up del mini player a esta pantalla tarda ~300ms (ver
      // _openNowPlaying en mini_player.dart); si la extracción de paleta
      // arranca en el primer frame (el post-frame callback que llama a este
      // método dispara casi al instante), su trabajo de CPU compite con esos
      // mismos frames animados y se sentía como un tranco/atasco al expandir.
      // Esperar a que la transición termine antes de decodificar evita el
      // solapamiento; `size` además le pide a PaletteGenerator una miniatura
      // en vez de la imagen a resolución completa, que es la otra mitad del
      // costo.
      await Future.delayed(const Duration(milliseconds: 320));
      if (!mounted) return;
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        FileImage(file),
        size: const Size(100, 100),
        maximumColorCount: 12,
      );

      final extractedColor =
          paletteGenerator.dominantColor?.color ??
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
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 30,
            color: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: StreamBuilder<MediaItem?>(
          stream: audioHandler.mediaItem,
          builder: (context, snapshot) {
            final item = snapshot.data;
            final playlistId = item?.extras?['playlist_id'] as String?;
            final playlistName = item?.album ?? '';
            final label = playlistName.isNotEmpty
                ? 'Reproduciendo desde $playlistName'
                : 'Reproduciendo';
            final text = Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                letterSpacing: 1.1,
              ),
            );
            if (playlistId == null || playlistId.isEmpty) return text;
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(
                context,
              ).pushNamed('/playlist', arguments: playlistId),
              child: text,
            );
          },
        ),
        centerTitle: true,
        actions: [
          StreamBuilder<PlaybackState>(
            stream: audioHandler.playbackState,
            builder: (context, stateSnapshot) {
              final state = stateSnapshot.data;
              final isShuffleActive =
                  state?.shuffleMode == AudioServiceShuffleMode.all;
              final isRepeatActive =
                  (state?.repeatMode ?? AudioServiceRepeatMode.none) !=
                  AudioServiceRepeatMode.none;

              return StreamBuilder<Duration?>(
                stream: audioHandler.sleepTimerStream,
                initialData: audioHandler.sleepTimerRemainingNow,
                builder: (context, sleepSnapshot) {
                  final isActive =
                      isShuffleActive ||
                      isRepeatActive ||
                      sleepSnapshot.data != null;

                  return IconButton(
                    icon: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.more_vert, color: Colors.white),
                        if (isActive)
                          Positioned(
                            right: -1,
                            top: -1,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF8C9EFF),
                              ),
                            ),
                          ),
                      ],
                    ),
                    onPressed: () =>
                        _showOptionsBottomSheet(context, audioHandler),
                  );
                },
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, mediaSnapshot) {
          final mediaItem = mediaSnapshot.data;
          if (mediaItem == null) {
            return Center(
              child: Text(
                l10n.nowPlayingNoMusic,
                style: const TextStyle(color: Colors.white54),
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // El arte fijo a 300px podía desbordar: horizontalmente en
                  // pantallas angostas (300 + 64 de padding = 364, más ancho
                  // que muchos Android reales de 360dp) y verticalmente en
                  // pantallas bajas, donde esta Column con spaceEvenly no
                  // tenía margen para acomodarlo. Se limita al menor entre el
                  // máximo original y lo que realmente entra en esta pantalla.
                  final artSize = math.min(
                    300.0,
                    math.min(
                      constraints.maxWidth - 64,
                      constraints.maxHeight * 0.38,
                    ),
                  );
                  return Column(
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
                            child: _buildAlbumArt(mediaItem, artSize),
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
                              mediaItem.artist ?? l10n.commonUnknownArtist,
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
                              icon: const Icon(
                                Icons.lyrics_outlined,
                                size: 18,
                                color: Colors.white,
                              ),
                              label: Text(
                                l10n.nowPlayingLyricsButton,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.08,
                                ),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                              ),
                              onPressed: () => _showLyricsBottomSheet(
                                context,
                                audioHandler,
                                mediaItem,
                                _dominantColor,
                              ),
                            ),
                            const SizedBox(width: 16),
                            ElevatedButton.icon(
                              icon: const Icon(
                                Icons.queue_music,
                                size: 18,
                                color: Colors.white,
                              ),
                              label: Text(
                                l10n.nowPlayingQueueButton,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.08,
                                ),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                              ),
                              onPressed: () =>
                                  _showQueueBottomSheet(context, audioHandler),
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

                          return SeekBar(
                            position: position,
                            duration: duration,
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

                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                // Every control sits in a 68-tall box (matching the play/pause
                                // circle) so the Row centers all five on the exact same line —
                                // IconButton's own minimum tap target height varies with iconSize
                                // (26 vs 36), which otherwise throws off the optical center.
                                SizedBox(
                                  height: 68,
                                  child: Center(
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.replay_5,
                                        color: Colors.white70,
                                        size: 26,
                                      ),
                                      tooltip: l10n.nowPlayingRewind5,
                                      onPressed: () =>
                                          audioHandler.seekRelative(
                                            const Duration(seconds: -5),
                                          ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: 68,
                                  child: Center(
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.skip_previous,
                                        color: Colors.white,
                                        size: 36,
                                      ),
                                      onPressed: () =>
                                          audioHandler.skipToPrevious(),
                                    ),
                                  ),
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
                                SizedBox(
                                  height: 68,
                                  child: Center(
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.skip_next,
                                        color: Colors.white,
                                        size: 36,
                                      ),
                                      onPressed: () =>
                                          audioHandler.skipToNext(),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: 68,
                                  child: Center(
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.forward_5,
                                        color: Colors.white70,
                                        size: 26,
                                      ),
                                      tooltip: l10n.nowPlayingForward5,
                                      onPressed: () =>
                                          audioHandler.seekRelative(
                                            const Duration(seconds: 5),
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  String _repeatModeLabel(BuildContext context, AudioServiceRepeatMode mode) {
    final l10n = AppLocalizations.of(context)!;
    switch (mode) {
      case AudioServiceRepeatMode.one:
        return l10n.nowPlayingRepeatOneLabel;
      case AudioServiceRepeatMode.all:
        return l10n.nowPlayingRepeatAllLabel;
      default:
        return l10n.nowPlayingOffLabel;
    }
  }

  String _formatRemaining(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _showOptionsBottomSheet(
    BuildContext context,
    AudioPlayerHandler audioHandler,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<PlaybackState>(
                stream: audioHandler.playbackState,
                builder: (context, snapshot) {
                  final state = snapshot.data;
                  final isShuffle =
                      state?.shuffleMode == AudioServiceShuffleMode.all;
                  final repeatMode =
                      state?.repeatMode ?? AudioServiceRepeatMode.none;
                  final isRepeatActive =
                      repeatMode != AudioServiceRepeatMode.none;

                  return Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.shuffle,
                          color: isShuffle
                              ? const Color(0xFF8C9EFF)
                              : Colors.white54,
                        ),
                        title: Text(
                          l10n.nowPlayingShuffleTitle,
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: Text(
                          isShuffle
                              ? l10n.nowPlayingOnLabel
                              : l10n.nowPlayingOffLabel,
                          style: TextStyle(
                            color: isShuffle
                                ? const Color(0xFF8C9EFF)
                                : Colors.white38,
                          ),
                        ),
                        onTap: () {
                          audioHandler.setShuffleMode(
                            isShuffle
                                ? AudioServiceShuffleMode.none
                                : AudioServiceShuffleMode.all,
                          );
                        },
                      ),
                      ListTile(
                        leading: Icon(
                          repeatMode == AudioServiceRepeatMode.one
                              ? Icons.repeat_one
                              : Icons.repeat,
                          color: isRepeatActive
                              ? const Color(0xFF8C9EFF)
                              : Colors.white54,
                        ),
                        title: Text(
                          l10n.nowPlayingRepeatTitle,
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: Text(
                          _repeatModeLabel(context, repeatMode),
                          style: TextStyle(
                            color: isRepeatActive
                                ? const Color(0xFF8C9EFF)
                                : Colors.white38,
                          ),
                        ),
                        onTap: () {
                          final next = switch (repeatMode) {
                            AudioServiceRepeatMode.none =>
                              AudioServiceRepeatMode.all,
                            AudioServiceRepeatMode.all =>
                              AudioServiceRepeatMode.one,
                            _ => AudioServiceRepeatMode.none,
                          };
                          audioHandler.setRepeatMode(next);
                        },
                      ),
                    ],
                  );
                },
              ),
              const Divider(color: Colors.white24, height: 1),
              StreamBuilder<Duration?>(
                stream: audioHandler.sleepTimerStream,
                initialData: audioHandler.sleepTimerRemainingNow,
                builder: (context, snapshot) {
                  final remaining = snapshot.data;
                  if (remaining != null) {
                    return ListTile(
                      leading: const Icon(
                        Icons.bedtime,
                        color: Color(0xFF8C9EFF),
                      ),
                      title: Text(
                        l10n.nowPlayingSleepTimerTitle,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        l10n.nowPlayingSleepTimerRemaining(
                          _formatRemaining(remaining),
                        ),
                        style: const TextStyle(color: Colors.white54),
                      ),
                      trailing: TextButton(
                        onPressed: () => audioHandler.cancelSleepTimer(),
                        child: Text(l10n.commonCancel),
                      ),
                    );
                  }
                  return ListTile(
                    leading: const Icon(
                      Icons.bedtime_outlined,
                      color: Colors.white54,
                    ),
                    title: Text(
                      l10n.nowPlayingSleepTimerTitle,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      l10n.nowPlayingSleepTimerBody,
                      style: const TextStyle(color: Colors.white38),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      // Use the screen's own stable context, not this
                      // StreamBuilder's — it belongs to the options sheet
                      // we're popping, and by the time the custom-minutes
                      // dialog chains off of it later it's already disposed.
                      _showSleepTimerPicker(this.context, audioHandler);
                    },
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showSleepTimerPicker(
    BuildContext context,
    AudioPlayerHandler audioHandler,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.nowPlayingSleepTimerTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...[15, 30, 45, 60].map((minutes) {
                      return ActionChip(
                        label: Text(
                          '$minutes min',
                          style: const TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        onPressed: () {
                          audioHandler.startSleepTimer(
                            Duration(minutes: minutes),
                          );
                          Navigator.of(sheetContext).pop();
                        },
                      );
                    }),
                    // Peer chip, not a buried link below the presets — same visual
                    // weight so a custom duration is just as discoverable.
                    ActionChip(
                      avatar: const Icon(
                        Icons.edit_outlined,
                        size: 16,
                        color: Color(0xFF8C9EFF),
                      ),
                      label: Text(
                        l10n.nowPlayingCustomChip,
                        style: const TextStyle(color: Color(0xFF8C9EFF)),
                      ),
                      backgroundColor: const Color(
                        0xFF8C9EFF,
                      ).withValues(alpha: 0.12),
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        final customMinutes = await _promptCustomMinutes(
                          context,
                        );
                        if (customMinutes != null) {
                          audioHandler.startSleepTimer(
                            Duration(minutes: customMinutes),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<int?> _promptCustomMinutes(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    const minMinutes = 1;
    const maxMinutes =
        720; // 12 h — generous upper bound against fat-finger input
    return showDialog<int>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: Text(
                l10n.nowPlayingMinutesDialogTitle,
                style: const TextStyle(color: Colors.white),
              ),
              content: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: l10n.nowPlayingMinutesHint(minMinutes, maxMinutes),
                  hintStyle: const TextStyle(color: Colors.white38),
                  errorText: errorText,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());
                    if (value == null ||
                        value < minMinutes ||
                        value > maxMinutes) {
                      setState(() {
                        errorText = l10n.nowPlayingMinutesError(
                          minMinutes,
                          maxMinutes,
                        );
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(value);
                  },
                  child: Text(l10n.commonAccept),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildAlbumArt(MediaItem item, double size) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    return SmartAlbumArt(artPath: artPath, title: item.title, size: size);
  }

  void _showLyricsBottomSheet(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    MediaItem mediaItem,
    Color dominantColor,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return LyricsBottomSheet(
          mediaItem: mediaItem,
          audioHandler: audioHandler,
          dominantColor: dominantColor,
        );
      },
    );
  }

  void _showQueueBottomSheet(
    BuildContext context,
    AudioPlayerHandler audioHandler,
  ) {
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
  final Color dominantColor;

  const LyricsBottomSheet({
    super.key,
    required this.mediaItem,
    required this.audioHandler,
    required this.dominantColor,
  });

  @override
  State<LyricsBottomSheet> createState() => _LyricsBottomSheetState();
}

class _LyricsBottomSheetState extends State<LyricsBottomSheet> {
  // La canción que se muestra ahora mismo. Antes el sheet sólo tenía el
  // `MediaItem` que le pasó el constructor (fijo mientras el sheet vive), así
  // que al pasar a la siguiente canción con el sheet abierto la letra
  // (y su resaltado) se quedaban congelados en la anterior. Ahora se
  // escucha `audioHandler.mediaItem` y este campo es lo único que el resto
  // de la clase lee — nunca `widget.mediaItem` fuera de `initState`.
  late MediaItem _item;
  StreamSubscription<MediaItem?>? _mediaItemSub;
  bool _isLoading = true;
  String? _lyricsText;
  List<LyricLine> _parsedLines = [];
  int _activeIndex = -1;
  bool _showTranslation = false;
  bool _isTranslating = false;
  List<String>? _translatedLines;
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _lyricKeys = [];
  StreamSubscription<Duration>? _positionSub;
  bool _userScrolling = false;
  DateTime _lastScrollTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _item = widget.mediaItem;
    // Antes esto vivía en un StreamBuilder<Duration> envolviendo TODA la
    // ListView de letras, así que cada tick de posición (varias veces por
    // segundo) reconstruía las líneas visibles enteras — con la traducción
    // sumando un segundo Text por línea, el costo se duplicaba y el
    // resaltado se sentía trabado/desincronizado. `_activeIndex` ahora es
    // estado real: sólo dispara `setState` cuando la línea activa cambia de
    // verdad (una vez cada tantos segundos), no en cada tick de posición.
    _positionSub = widget.audioHandler.player.positionStream.listen(
      _onPosition,
    );
    _mediaItemSub = widget.audioHandler.mediaItem.listen(_onMediaItemChanged);
    _fetchLyrics();
  }

  void _onMediaItemChanged(MediaItem? item) {
    if (item == null || item.id == _item.id) return;
    final wasShowingTranslation = _showTranslation;
    setState(() {
      _item = item;
      _isLoading = true;
      _lyricsText = null;
      _parsedLines = [];
      _lyricKeys.clear();
      _activeIndex = -1;
      _translatedLines = null;
      _showTranslation = false;
    });
    _fetchLyrics(reTranslateAfter: wasShowingTranslation);
  }

  void _onPosition(Duration position) {
    if (_parsedLines.isEmpty) return;
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
      setState(() => _activeIndex = newActiveIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActiveLine(_activeIndex);
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mediaItemSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _fetchLyrics({bool reTranslateAfter = false}) async {
    // Se captura el id pedido: si la canción vuelve a cambiar mientras esta
    // petición está en vuelo, la respuesta llega tarde y no debe pisar la
    // letra de la canción que ya está sonando ahora.
    final requestedSongId = _item.id;
    try {
      final lyrics = await LyricsService.instance.getLyrics(
        songId: requestedSongId,
        title: _item.title,
        artist: _item.artist ?? '',
        durationSeconds: _item.duration?.inSeconds ?? 0,
      );
      if (!mounted || _item.id != requestedSongId) return;

      if (lyrics != null && lyrics.isNotEmpty) {
        final lines = LyricsService.instance.parseLrc(lyrics);
        setState(() {
          _lyricsText = lyrics;
          _parsedLines = lines;
          _lyricKeys.clear();
          _lyricKeys.addAll(List.generate(lines.length, (_) => GlobalKey()));
          _isLoading = false;
        });
      } else {
        setState(() {
          _lyricsText = null;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error fetching lyrics: $e');
      if (mounted && _item.id == requestedSongId) {
        setState(() {
          _lyricsText = null;
          _isLoading = false;
        });
      }
      return;
    }
    if (reTranslateAfter && _lyricsText != null && _item.id == requestedSongId) {
      await _toggleTranslation();
    }
  }

  Future<void> _toggleTranslation() async {
    if (_lyricsText == null) return;
    if (_showTranslation) {
      setState(() => _showTranslation = false);
      return;
    }
    if (_translatedLines != null) {
      setState(() => _showTranslation = true);
      return;
    }

    setState(() => _isTranslating = true);
    final targetLang = context.read<SettingsProvider>().language.name;
    final requestedSongId = _item.id;
    final sourceLines = _parsedLines.isNotEmpty
        ? _parsedLines.map((l) => l.text).toList()
        : _lyricsText!.split('\n');
    try {
      final translated = await TranslationService.instance.translateLines(
        songId: requestedSongId,
        lines: sourceLines,
        targetLang: targetLang,
      );
      if (mounted && _item.id == requestedSongId) {
        setState(() {
          _translatedLines = translated;
          _showTranslation = true;
          _isTranslating = false;
        });
      }
    } catch (e) {
      print('Error traduciendo letra: $e');
      if (mounted && _item.id == requestedSongId) {
        setState(() => _isTranslating = false);
      }
    }
  }

  void _scrollToActiveLine(int index) {
    if (index < 0 || index >= _lyricKeys.length) return;

    if (_userScrolling &&
        DateTime.now().difference(_lastScrollTime).inSeconds < 3) {
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
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              widget.dominantColor.withValues(alpha: 0.4),
              Colors.black.withValues(alpha: 0.82),
            ],
            stops: const [0.0, 0.6],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 20.0,
                vertical: 8.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Letra',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          [
                            _item.title,
                            if ((_item.artist ?? '').isNotEmpty) _item.artist!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      if (_isTranslating)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        IconButton(
                          icon: Icon(
                            Icons.translate_rounded,
                            color: _showTranslation
                                ? const Color(0xFF8C9EFF)
                                : Colors.white70,
                          ),
                          onPressed: _lyricsText == null
                              ? null
                              : _toggleTranslation,
                        ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
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
                  ? Center(
                      child: Text(
                        AppLocalizations.of(context)!.lyricsUnavailable,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 16,
                        ),
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
                          ? ListView.builder(
                              controller: _scrollController,
                              itemCount: _parsedLines.length,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 20,
                              ),
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
                                      color: isActive
                                          ? Colors.white
                                          : Colors.white38,
                                      fontSize: isActive ? 21 : 18,
                                      fontWeight: isActive
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                      height: 1.5,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10.0,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            line.text,
                                            textAlign: TextAlign.left,
                                          ),
                                          if (_showTranslation &&
                                              _translatedLines != null &&
                                              index <
                                                  _translatedLines!.length &&
                                              _translatedLines![index]
                                                  .trim()
                                                  .isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                _translatedLines![index],
                                                textAlign: TextAlign.left,
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.4),
                                                  fontSize:
                                                      (isActive ? 21 : 18) - 4,
                                                  fontStyle: FontStyle.italic,
                                                  fontWeight: FontWeight.w400,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(24.0),
                              child:
                                  _showTranslation && _translatedLines != null
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: List.generate(
                                        _lyricsText!.split('\n').length,
                                        (index) {
                                          final plainLines = _lyricsText!.split(
                                            '\n',
                                          );
                                          final original = plainLines[index];
                                          final translation =
                                              index < _translatedLines!.length
                                              ? _translatedLines![index]
                                              : '';
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 10,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  original,
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 18,
                                                    height: 1.6,
                                                  ),
                                                ),
                                                if (translation
                                                    .trim()
                                                    .isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 2,
                                                        ),
                                                    child: Text(
                                                      translation,
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.4,
                                                            ),
                                                        fontSize: 14,
                                                        fontStyle:
                                                            FontStyle.italic,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    )
                                  : Text(
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

  const QueueBottomSheet({super.key, required this.audioHandler});

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
    final l10n = AppLocalizations.of(context)!;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        height: media.size.height * 0.85,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 20.0,
                vertical: 8.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l10n.queueTitle,
                    style: const TextStyle(
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
                    return Center(
                      child: Text(
                        l10n.queueEmpty,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 16,
                        ),
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
                              child: const Icon(
                                Icons.delete,
                                color: Colors.white,
                              ),
                            ),
                            onDismissed: (_) {
                              widget.audioHandler.removeQueueItem(item);
                            },
                            child: Material(
                              key: ValueKey('tile_${item.id}'),
                              color: isPlaying
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.transparent,
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
                                    color: isPlaying
                                        ? const Color(0xFF8C9EFF)
                                        : Colors.white,
                                    fontWeight: isPlaying
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: 15,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.artist ?? l10n.commonUnknownArtist} • ${_formatDuration(item.duration)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isPlaying
                                        ? const Color(
                                            0xFF8C9EFF,
                                          ).withValues(alpha: 0.7)
                                        : Colors.white38,
                                    fontSize: 13,
                                  ),
                                ),
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: Icon(
                                      Icons.drag_handle,
                                      color: Colors.white38,
                                    ),
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
    return SmartAlbumArt(artPath: artPath, title: item.title, size: 48);
  }
}

// --- SEEK BAR ---
// Collapsed from a WaveformSeekBar (D7, Stage 5 prune): AudioAnalysisService
// never did real waveform extraction (it derived fake bar heights from
// filePath.hashCode, falling back to a raw Random() on failure — see
// CLAUDE.md), and it depended on `File(path)`, which can't read a SAF
// content:// uri anyway. Deleted rather than fixed — a decorative feature
// that was never doing what it looked like it did.
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
    final maxMs = widget.duration.inMilliseconds.toDouble();
    final hasDuration = maxMs > 0;
    final value = (_dragValue ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, hasDuration ? maxMs : 1.0);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: const Color(0xFF8C9EFF),
            inactiveTrackColor: Colors.white10,
            thumbColor: const Color(0xFF8C9EFF),
          ),
          child: Slider(
            min: 0,
            max: hasDuration ? maxMs : 1,
            value: hasDuration ? value : 0,
            onChanged: hasDuration
                ? (v) => setState(() => _dragValue = v)
                : null,
            onChangeEnd: hasDuration
                ? (v) {
                    widget.onChangeEnd(Duration(milliseconds: v.toInt()));
                    setState(() => _dragValue = null);
                  }
                : null,
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

// --- SMART ALBUM ART (DYNAMIC ASPECT CROP) ---
class SmartAlbumArt extends StatefulWidget {
  final String artPath;
  final String title;
  final double size;

  const SmartAlbumArt({
    super.key,
    required this.artPath,
    required this.title,
    required this.size,
  });

  @override
  State<SmartAlbumArt> createState() => _SmartAlbumArtState();
}

class _SmartAlbumArtState extends State<SmartAlbumArt> {
  // Consistent policy with song_tile/home_screen/mini_player: always a centered
  // square crop via BoxFit.cover. No per-image aspect-ratio branching needed.
  late bool _hasError = _isMissing(widget.artPath);

  static bool _isMissing(String path) =>
      path.isEmpty || !File(path).existsSync();

  @override
  void didUpdateWidget(covariant SmartAlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artPath != widget.artPath) {
      setState(() {
        _hasError = _isMissing(widget.artPath);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return _buildPlaceholder();
    }

    // Sin límite de decodificación, Image.file decodifica la carátula a su
    // resolución original (puede ser varios cientos de KB de un thumbnail de
    // YouTube o un embed de ID3) para mostrarla en un cuadro de `size` — ese
    // decode de más era parte del atasco al abrir esta pantalla desde el mini
    // player. Pedirle al decoder el tamaño real de destino, en píxeles
    // físicos, evita el trabajo sobrante.
    //
    // **SÓLO `cacheHeight`, nunca las dos a la vez.** Con `cacheWidth` Y
    // `cacheHeight`, `instantiateImageCodec` redimensiona a exactamente esas
    // dimensiones **ignorando la relación de aspecto**: una miniatura 16:9
    // quedaba aplastada a un cuadrado, así que `BoxFit.cover` ya no tenía
    // nada que recortar y las franjas negras que traen incrustadas muchas
    // miniaturas de YouTube (una carátula cuadrada centrada sobre un lienzo
    // 16:9) se quedaban a la vista como barras a los lados. Fijando sólo el
    // alto, el decoder conserva la proporción, el ancho queda mayor que el
    // cuadro y `BoxFit.cover` recorta los bordes — que es justo lo que hace
    // que en la lista (`song_tile`, sin límites de decode) siempre se vieran
    // bien y sólo aquí no.
    final cacheSize = (widget.size * MediaQuery.of(context).devicePixelRatio)
        .round();
    return Image.file(
      File(widget.artPath),
      fit: BoxFit.cover,
      width: widget.size,
      height: widget.size,
      cacheHeight: cacheSize,
      errorBuilder: (_, __, ___) => _buildPlaceholder(),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        gradient: AppTheme.gradientForTitle(widget.title),
      ),
      child: Icon(
        Icons.music_note,
        color: Colors.white70,
        size: widget.size * 0.5,
      ),
    );
  }
}
