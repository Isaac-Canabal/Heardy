import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/now_playing_screen.dart';
import '../services/audio_player_handler.dart';

/// El "reproduciendo ahora" del escritorio: la misma información que
/// `NowPlayingScreen` en el teléfono (carátula, título, artista, controles),
/// pero como columna fija a la derecha del shell en vez de una ruta a
/// pantalla completa, con la letra y la cola debajo de la carátula. La línea
/// de tiempo y el volumen no viven acá sino en la barra inferior del
/// contenido (`DesktopPlaybackBar`).
class DesktopNowPlayingPanel extends StatefulWidget {
  final VoidCallback onClose;
  final ValueChanged<String> onOpenPlaylist;

  const DesktopNowPlayingPanel({
    super.key,
    required this.onClose,
    required this.onOpenPlaylist,
  });

  @override
  State<DesktopNowPlayingPanel> createState() => _DesktopNowPlayingPanelState();
}

class _DesktopNowPlayingPanelState extends State<DesktopNowPlayingPanel> {
  String? _currentId;
  Color _dominantColor = kNowPlayingFallbackColor;
  int _tab = 0;

  Future<void> _updatePalette(MediaItem item) async {
    final artPath = item.extras?['artPath'] as String? ?? '';
    final color = await dominantColorForArt(artPath);
    if (mounted && _currentId == item.id) {
      setState(() => _dominantColor = color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final audioHandler = context.read<AudioPlayerHandler>();
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) {
          return _Frame(
            color: _dominantColor,
            child: Column(
              children: [
                _header(context, audioHandler, null),
                Expanded(
                  child: Center(
                    child: Text(
                      l10n.nowPlayingNoMusic,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (_currentId != item.id) {
          _currentId = item.id;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _updatePalette(item),
          );
        }

        return _Frame(
          color: _dominantColor,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final artSize = math.min(
                constraints.maxWidth - 56,
                constraints.maxHeight * 0.34,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, audioHandler, item),
                  const SizedBox(height: 4),
                  Center(
                    child: Card(
                      elevation: 12,
                      shadowColor: _dominantColor.withValues(alpha: 0.35),
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SmartAlbumArt(
                          artPath: item.extras?['artPath'] as String? ?? '',
                          title: item.title,
                          size: artSize,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                    child: Column(
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.artist ?? l10n.commonUnknownArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Controls(audioHandler: audioHandler),
                  const SizedBox(height: 6),
                  _tabs(context),
                  const Divider(color: Colors.white12, height: 1),
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      children: [
                        LyricsBottomSheet(
                          // Una sola instancia para todo el panel: el sheet
                          // se suscribe al stream de `mediaItem` y se
                          // actualiza solo al cambiar de canción.
                          key: const ValueKey('desktop-lyrics'),
                          mediaItem: item,
                          audioHandler: audioHandler,
                          dominantColor: _dominantColor,
                          embedded: true,
                        ),
                        QueueBottomSheet(
                          key: const ValueKey('desktop-queue'),
                          audioHandler: audioHandler,
                          embedded: true,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _header(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    MediaItem? item,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final playlistId = item?.extras?['playlist_id'] as String?;
    final playlistName = item?.album ?? '';
    final label = playlistName.isNotEmpty
        ? l10n.desktopNowPlayingFrom(playlistName)
        : l10n.desktopNowPlaying;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
        letterSpacing: 1.0,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.desktopHideNowPlaying,
            icon: const Icon(
              Icons.keyboard_double_arrow_right_rounded,
              color: Colors.white70,
            ),
            onPressed: widget.onClose,
          ),
          Expanded(
            child: playlistId == null || playlistId.isEmpty
                ? labelText
                : InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onOpenPlaylist(playlistId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: labelText,
                    ),
                  ),
          ),
          StreamBuilder<Duration?>(
            stream: audioHandler.sleepTimerStream,
            initialData: audioHandler.sleepTimerRemainingNow,
            builder: (context, snapshot) {
              final active = snapshot.data != null;
              return IconButton(
                tooltip: l10n.nowPlayingSleepTimerTitle,
                icon: Icon(
                  active ? Icons.bedtime : Icons.bedtime_outlined,
                  color: active ? const Color(0xFF8C9EFF) : Colors.white70,
                ),
                onPressed: () => active
                    ? audioHandler.cancelSleepTimer()
                    : showSleepTimerPicker(context, audioHandler),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStatePropertyAll(
            BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.white60,
          ),
        ),
        segments: [
          ButtonSegment(
            value: 0,
            icon: const Icon(Icons.lyrics_outlined, size: 16),
            label: Text(l10n.nowPlayingLyricsButton),
          ),
          ButtonSegment(
            value: 1,
            icon: const Icon(Icons.queue_music, size: 16),
            label: Text(l10n.nowPlayingQueueButton),
          ),
        ],
        selected: {_tab},
        onSelectionChanged: (s) => setState(() => _tab = s.first),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  final Color color;
  final Widget child;
  const _Frame({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.4), const Color(0xFF0D0D0D)],
          stops: const [0.0, 0.85],
        ),
      ),
      child: child,
    );
  }
}

/// Aleatorio · anterior · play/pausa · siguiente · repetir. Sin los ±5 s del
/// teléfono: en el escritorio las flechas del teclado ya hacen eso.
class _Controls extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  const _Controls({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final shuffle = state?.shuffleMode == AudioServiceShuffleMode.all;
        final repeat = state?.repeatMode ?? AudioServiceRepeatMode.none;
        final repeatOn = repeat != AudioServiceRepeatMode.none;
        const active = Color(0xFF8C9EFF);

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: l10n.nowPlayingShuffleTitle,
              icon: Icon(
                Icons.shuffle_rounded,
                size: 22,
                color: shuffle ? active : Colors.white60,
              ),
              onPressed: () => audioHandler.setShuffleMode(
                shuffle
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.skip_previous_rounded,
                size: 34,
                color: Colors.white,
              ),
              onPressed: () => audioHandler.skipToPrevious(),
            ),
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: IconButton(
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.black,
                  size: 32,
                ),
                onPressed: () =>
                    playing ? audioHandler.pause() : audioHandler.play(),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.skip_next_rounded,
                size: 34,
                color: Colors.white,
              ),
              onPressed: () => audioHandler.skipToNext(),
            ),
            IconButton(
              tooltip: l10n.nowPlayingRepeatTitle,
              icon: Icon(
                repeat == AudioServiceRepeatMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                size: 22,
                color: repeatOn ? active : Colors.white60,
              ),
              onPressed: () => audioHandler.setRepeatMode(switch (repeat) {
                AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                _ => AudioServiceRepeatMode.none,
              }),
            ),
          ],
        );
      },
    );
  }
}
