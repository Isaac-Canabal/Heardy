import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/music_provider.dart';
import '../services/database_helper.dart';
import '../providers/download_provider.dart';
import '../services/audio_player_handler.dart';
import '../models/song.dart';
import '../widgets/song_tile.dart';
import '../theme/app_theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final musicProvider = Provider.of<MusicProvider>(context);
    final audioHandler = Provider.of<AudioPlayerHandler>(context);

    // Fetch the active playlist metadata
    final playlist = musicProvider.playlists.firstWhere(
      (p) => p.id == widget.playlistId,
      orElse: () => musicProvider.currentPlaylistSongs.isNotEmpty
          ? musicProvider.playlists.firstWhere((p) => p.id == widget.playlistId)
          : musicProvider.playlists.first, // fallback if deleted
    );

    // Filter and sort tracks based on search bar and sort option
    final allSongs = musicProvider.currentPlaylistSongs;
    var filteredSongs = allSongs.where((song) {
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
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Renombrar Lista',
            onPressed: () => _showRenamePlaylistDialog(context, playlist.name),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Eliminar Lista',
            onPressed: () => _showDeletePlaylistDialog(context, playlist.name),
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
            tooltip: 'Borrar todas las canciones',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Confirmar borrado'),
                  content: const Text('¿Quieres eliminar todas las canciones de esta playlist del dispositivo?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
                    TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Eliminar')),
                  ],
                ),
              );
              if (confirm == true) {
                await Provider.of<MusicProvider>(context, listen: false)
                    .deleteAllSongsFromPlaylist(playlist.id);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Canciones eliminadas')));
              }
            },
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Column(
          children: [
            // Sleek premium search field
            if (allSongs.isNotEmpty) _buildSearchField(),
            // Playlist songs list
            Expanded(
              child: allSongs.isEmpty
                  ? _buildEmptyState()
                  : filteredSongs.isEmpty
                      ? _buildNoResultsState()
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

                                // Dismissible tile to support swipe-to-delete
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
                                    await musicProvider.removeSongFromPlaylist(
                                        widget.playlistId, song.id);
                                    // Refresh audio handler queue if this is the current playlist
                                    if (musicProvider.currentPlaylistId == widget.playlistId) {
                                      await musicProvider.refreshAudioHandlerQueue(audioHandler);
                                    }
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Se eliminó "${song.title}" de la lista'),
                                          backgroundColor: Colors.indigo[900],
                                        ),
                                      );
                                    }
                                  },
                                  child: SongTile(
                                    song: song,
                                    isPlaying: isPlaying,
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
      ),
    );
  }

  String _getSortLabel(String sortBy) {
    switch (sortBy) {
      case 'manual':
        return 'Orden de importación';
      case 'artist':
        return 'Artista';
      case 'title':
        return 'Título';
      case 'duration':
        return 'Duración';
      default:
        return 'Desconocido';
    }
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
              'Ve al buscador de YouTube para descargar y añadir música aquí.',
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
          'filePath': song.filePath,
          'artPath': song.artPath,
        },
      );
    }).toList();

    await audioHandler.playPlaylist(mediaItems, targetSong.id);
  }

  void _showRenamePlaylistDialog(BuildContext context, String currentName) {
    _renameController.text = currentName;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            'Renombrar lista',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: _renameController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Nuevo nombre',
              hintStyle: TextStyle(color: Colors.grey[600]),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF3F51B5)),
              ),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                final name = _renameController.text.trim();
                if (name.isNotEmpty && name != currentName) {
                  Provider.of<MusicProvider>(context, listen: false)
                      .renamePlaylist(widget.playlistId, name);
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Renombrar', style: TextStyle(color: Color(0xFF3F51B5))),
            ),
          ],
        );
      },
    );
  }

  void _showDeletePlaylistDialog(BuildContext context, String playlistName) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            '¿Eliminar lista?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            '¿Estás seguro de que deseas eliminar "$playlistName"? Las canciones descargadas seguirán en tu dispositivo, pero la lista se borrará.',
            style: TextStyle(color: Colors.grey[400]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                Provider.of<DownloadProvider>(context, listen: false).clearQueueForPlaylist(widget.playlistId);
                Provider.of<MusicProvider>(context, listen: false)
                    .deletePlaylist(widget.playlistId);
                Navigator.of(context).pop(); // close dialog
                Navigator.of(context).pop(); // return to home
              },
              child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }
}
