import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/download_source.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player.dart';
import '../theme/app_theme.dart';

/// Entradas de [remote] cuyo `sourceUrl` todavía no está entre las canciones
/// ya presentes en la playlist ([existingSongs]) — lo que decide qué se
/// vuelve a encolar al "Actualizar desde YouTube" sin descargar dos veces lo
/// mismo. Aparte como función pura para poder probarla sin necesitar un
/// `AudioPlayerHandler` real (que arrastra `just_audio`/canales de
/// plataforma, y para el que este proyecto no tiene ningún fake de test).
@visibleForTesting
List<RemoteTrack> missingPlaylistEntries(RemotePlaylist remote, List<Song> existingSongs) {
  final existingUrls = existingSongs.map((s) => s.sourceUrl).whereType<String>().toSet();
  return remote.entries.where((e) => !existingUrls.contains(e.sourceUrl)).toList();
}

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _renameController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'manual'; // manual, artist, title, date
  bool _isReordering = false;
  bool _isUpdatingFromYoutube = false;
  final List<String> _temporarilyRemovedSongIds = [];

  @override
  void initState() {
    super.initState();
    // Load playlist tracks when screen mounts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<MusicProvider>(context, listen: false)
          .loadSongsForPlaylist(widget.playlistId);
    });
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _renameController.dispose();
    super.dispose();
  }

  /// Expande de nuevo la playlist de origen y encola sólo lo que falta,
  /// comparando por `song.sourceUrl` — nunca vuelve a descargar lo que ya
  /// está. Sólo aparece para playlists con `originalUrl` (creadas desde una
  /// URL de YouTube en ImportScreen).
  Future<void> _updateFromYoutube(Playlist playlist) async {
    final originalUrl = playlist.originalUrl;
    if (originalUrl == null || originalUrl.isEmpty || _isUpdatingFromYoutube) return;

    setState(() => _isUpdatingFromYoutube = true);
    try {
      final musicProvider = context.read<MusicProvider>();
      final downloadProvider = context.read<DownloadProvider>();
      final source = context.read<DownloadSource>();

      final remote = await source.resolvePlaylist(originalUrl);
      final missing = missingPlaylistEntries(remote, musicProvider.currentPlaylistSongs);

      if (!mounted) return;
      if (missing.isEmpty) {
        _showSnack('Ya está actualizada, no hay canciones nuevas');
        return;
      }

      final added = await downloadProvider.enqueuePlaylist(
        RemotePlaylist(id: remote.id, name: remote.name, sourceUrl: remote.sourceUrl, entries: missing),
        playlistId: playlist.id,
      );
      downloadProvider.processQueue();
      if (!mounted) return;
      _showSnack('$added ${added == 1 ? "canción nueva encolada" : "canciones nuevas encoladas"}');
    } on DownloadSourceException catch (e) {
      if (!mounted) return;
      _showSnack(e.userMessage, isError: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('No se pudo actualizar: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isUpdatingFromYoutube = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.withValues(alpha: 0.8) : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final musicProvider = Provider.of<MusicProvider>(context);
    final audioHandler = Provider.of<AudioPlayerHandler>(context);

    // Fetch the active playlist metadata.
    //
    // Esto era un `firstWhere` cuyo `orElse` —el camino para "no encontrada"—
    // repetía la MISMA búsqueda sin `orElse`, así que lanzaba StateError justo en
    // el caso que pretendía cubrir; y su otra rama, `playlists.first`, lanzaba
    // igual si no quedaba ninguna playlist. Borrar la playlist que estabas viendo
    // reventaba `build()` con pantalla roja.
    final matches =
        musicProvider.playlists.where((p) => p.id == widget.playlistId);
    if (matches.isEmpty) {
      return _PlaylistGoneScaffold();
    }
    final playlist = matches.first;

    // Filter and sort tracks based on search bar and sort option
    final allSongs = musicProvider.currentPlaylistSongs;
    var filteredSongs = allSongs.where((song) {
      if (_temporarilyRemovedSongIds.contains(song.id)) return false;
      final titleMatch = song.title.toLowerCase().contains(_searchQuery);
      final artistMatch = song.artist.toLowerCase().contains(_searchQuery);
      return titleMatch || artistMatch;
    }).toList();

    // Apply sorting
    if (_sortBy == 'artist') {
      filteredSongs.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
    } else if (_sortBy == 'title') {
      filteredSongs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sortBy == 'duration') {
      filteredSongs.sort((a, b) => a.duration.compareTo(b.duration));
    }
    // manual = keep original order (import order)

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          if (playlist.originalUrl != null && playlist.originalUrl!.isNotEmpty)
            IconButton(
              icon: _isUpdatingFromYoutube
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              tooltip: 'Actualizar desde YouTube',
              onPressed: _isUpdatingFromYoutube ? null : () => _updateFromYoutube(playlist),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            tooltip: 'Ordenar',
            onSelected: (value) {
              setState(() {
                _sortBy = value;
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'manual',
                child: Row(
                  children: [
                    Icon(Icons.list_rounded),
                    SizedBox(width: 12),
                    Text('Orden de importación'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'artist',
                child: Row(
                  children: [
                    Icon(Icons.person_rounded),
                    SizedBox(width: 12),
                    Text('Artista'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'title',
                child: Row(
                  children: [
                    Icon(Icons.music_note_rounded),
                    SizedBox(width: 12),
                    Text('Título'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'duration',
                child: Row(
                  children: [
                    Icon(Icons.timer_rounded),
                    SizedBox(width: 12),
                    Text('Duración'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: Icon(_isReordering ? Icons.done : Icons.edit_outlined),
            tooltip: _isReordering ? 'Terminar edición' : 'Modificar orden',
            onPressed: () {
              setState(() {
                _isReordering = !_isReordering;
                if (_isReordering) {
                  _sortBy = 'manual'; // Force manual sort for reordering
                }
              });
            },
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            Column(
              children: [
                // Sleek premium search field
                if (allSongs.isNotEmpty) _buildSearchField(),
                // Playlist songs list
                Expanded(
              child: allSongs.isEmpty
                  ? _buildEmptyState()
                  : filteredSongs.isEmpty
                      ? _buildNoResultsState()
                      : _isReordering
                          ? ReorderableListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 90),
                              itemCount: filteredSongs.length,
                              onReorder: (oldIndex, newIndex) async {
                                if (oldIndex < newIndex) {
                                  newIndex -= 1;
                                }
                                final song = filteredSongs.removeAt(oldIndex);
                                filteredSongs.insert(newIndex, song);
                                final List<String> songIds = filteredSongs.map((s) => s.id).toList();
                                await musicProvider.reorderSongsInPlaylist(widget.playlistId, songIds);
                              },
                              itemBuilder: (context, index) {
                                final song = filteredSongs[index];
                                return Container(
                                  key: Key(song.id),
                                  color: Colors.transparent, // Need color for ReorderableListView dragging
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: SongTile(
                                          song: song,
                                          isPlaying: false,
                                          index: index,
                                          onTap: () {},
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                                        child: Icon(Icons.drag_handle, color: Colors.white54),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 90),
                              itemCount: filteredSongs.length,
                              itemBuilder: (context, index) {
                                final song = filteredSongs[index];

                                return StreamBuilder<MediaItem?>(
                                  stream: audioHandler.mediaItem,
                                  builder: (context, mediaSnapshot) {
                                    final activeItem = mediaSnapshot.data;
                                    final isPlaying = activeItem?.id == song.id;

                                    return Dismissible(
                                      key: Key(song.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        color: Colors.redAccent[700],
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 24),
                                        margin: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 6),
                                        child: const Icon(
                                          Icons.delete_sweep,
                                          color: Colors.white,
                                          size: 28,
                                        ),
                                      ),
                                      onDismissed: (direction) async {
                                        final songId = song.id;
                                        final songTitle = song.title;

                                        setState(() {
                                          _temporarilyRemovedSongIds.add(songId);
                                        });

                                        bool undoClicked = false;
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).clearSnackBars();
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Se eliminó "$songTitle" de la lista'),
                                              backgroundColor: Colors.indigo[900],
                                              duration: const Duration(seconds: 4),
                                              action: SnackBarAction(
                                                label: 'Deshacer',
                                                textColor: Colors.amberAccent,
                                                onPressed: () {
                                                  undoClicked = true;
                                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                                  if (mounted) {
                                                    setState(() {
                                                      _temporarilyRemovedSongIds.remove(songId);
                                                    });
                                                  }
                                                },
                                              ),
                                            ),
                                          ).closed.then((reason) async {
                                            if (!undoClicked) {
                                              await musicProvider.removeSongFromPlaylist(
                                                  widget.playlistId, songId);
                                              if (musicProvider.currentPlaylistId == widget.playlistId) {
                                                await musicProvider.refreshAudioHandlerQueue(audioHandler);
                                              }
                                            }
                                            _temporarilyRemovedSongIds.remove(songId);
                                          });
                                        }
                                      },
                                      child: SongTile(
                                        song: song,
                                        isPlaying: isPlaying,
                                        index: index,
                                        onTap: () => _playSong(
                                            audioHandler, filteredSongs, song, playlist.name),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MiniPlayer(),
            ),
          ],
        ),
      ),
    );
  }



  Widget _buildSearchField() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 100, 16, 8),
      decoration: AppTheme.glassCard(),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Buscar en esta lista...',
          hintStyle: TextStyle(color: Colors.grey[600], fontSize: 14),
          prefixIcon: Icon(Icons.search, color: AppTheme.primaryLight),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white70),
                  onPressed: () => _searchController.clear(),
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_off_outlined,
              size: 70,
              color: Colors.grey[800],
            ),
            const SizedBox(height: 16),
            const Text(
              'No hay canciones en esta lista',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Metés archivos en tu carpeta o descargás desde la pestaña Añadir.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_outlined,
              size: 60,
              color: Colors.grey[800],
            ),
            const SizedBox(height: 16),
            const Text(
              'Sin resultados',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ninguna canción coincide con "$_searchQuery".',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Map entire playlist items to MediaItem instances, load the queue, and play target song.
  Future<void> _playSong(AudioPlayerHandler audioHandler, List<Song> playlistSongs, Song targetSong, String playlistName) async {
    final List<MediaItem> mediaItems = playlistSongs.map((song) {
      return MediaItem(
        id: song.id,
        album: playlistName,
        title: song.title,
        artist: song.artist,
        duration: Duration(seconds: song.duration),
        artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
        extras: {
          'filePath': song.playablePath,
          'artPath': song.artPath,
        },
      );
    }).toList();

    await audioHandler.playPlaylist(mediaItems, targetSong.id);
  }

}

/// Pantalla mínima para cuando la playlist que se estaba viendo ya no existe
/// (borrada desde otra pantalla mientras esta seguía en la pila de navegación).
///
/// Antes esto no existía y el caso terminaba en StateError dentro de `build()`.
/// Se resuelve con una salida explícita en vez de intentar adivinar otra
/// playlist, que es lo que hacía el `orElse` roto: mostrar contenido de una
/// playlist distinta a la que el usuario abrió sería peor que decirle la verdad.
class _PlaylistGoneScaffold extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist no disponible')),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.playlist_remove_rounded,
                  size: 56,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 16),
                Text(
                  'Esta playlist ya no existe.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Volver'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
