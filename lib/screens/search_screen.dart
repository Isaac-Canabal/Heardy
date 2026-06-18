import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/youtube_service.dart';
import '../providers/music_provider.dart';
import '../providers/download_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final YoutubeService _youtubeService = YoutubeService();
  
  List<YouTubeSearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _errorMessage;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _hasSearched = false;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _hasSearched = true;
      _errorMessage = null;
      _searchResults = [];
    });

    try {
      final settingsProvider = Provider.of<SettingsProvider>(context, listen: false);
      final results = await _youtubeService.searchVideos(
        query, 
        maxResults: settingsProvider.maxSearchResults
      );
      
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
          if (results.isEmpty) {
            _errorMessage = 'No se encontraron resultados';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _errorMessage = 'Error en la búsqueda: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _addToPlaylist(YouTubeSearchResult result) async {
    final musicProvider = Provider.of<MusicProvider>(context, listen: false);
    final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
    
    // Mostrar diálogo para seleccionar playlist
    final playlists = musicProvider.playlists;
    
    if (playlists.isEmpty) {
      _showSnackBar('No tienes playlists. Crea una primero.', isError: true);
      return;
    }

    final selectedPlaylistId = await showDialog<String>(
      context: context,
      builder: (context) => _SelectPlaylistDialog(playlists: playlists),
    );

    if (selectedPlaylistId != null && mounted) {
      try {
        await downloadProvider.downloadVideo(result.url, selectedPlaylistId);
        
        if (downloadProvider.errorMessage != null) {
          _showSnackBar(downloadProvider.errorMessage!, isError: true);
          downloadProvider.clearError();
        } else {
          _showSnackBar('Añadiendo a descarga...', isSuccess: true);
          await musicProvider.loadPlaylists();
        }
      } catch (e) {
        _showSnackBar('Error añadiendo a playlist: $e', isError: true);
      }
    }
  }

  Future<void> _playDirectly(YouTubeSearchResult result) async {
    // Temporalmente deshabilitado debido a limitaciones de streaming de YouTube
    // Las URLs de YouTube no son compatibles con reproductores de audio estándar
    // Por ahora, el usuario debe descargar primero
    _showSnackBar('Por favor descarga primero para reproducir. El streaming de YouTube requiere descarga previa.', isError: true);
    return;
    
    /* Streaming directo deshabilitado temporalmente
    final audioHandler = Provider.of<AudioPlayerHandler>(context, listen: false);
    
    try {
      _showSnackBar('Cargando audio de alta calidad...', isSuccess: true);
      
      final streamingUrl = await _youtubeService.getStreamingUrl(result.videoId);
      if (streamingUrl == null) {
        _showSnackBar('Error cargando audio. Intenta descargar primero.', isError: true);
        return;
      }
      
      // Crear MediaItem para reproducción temporal
      final mediaItem = MediaItem(
        id: result.videoId,
        title: result.title,
        artist: result.artist,
        duration: result.duration,
        artUri: Uri.parse(result.thumbnailUrl),
        extras: {
          'is_streaming': true,
          'streaming_url': streamingUrl,
        },
      );
      
      // Configurar el handler para streaming
      await audioHandler.playUrl(streamingUrl, mediaItem);
      
      _showSnackBar('Reproduciendo streaming...', isSuccess: true);
    } catch (e) {
      _showSnackBar('Error reproduciendo: $e', isError: true);
    }
    */
  }

  void _showSnackBar(String message, {bool isError = false, bool isSuccess = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.redAccent.shade700
            : isSuccess
                ? const Color(0xFF059669)
                : AppTheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Buscar música',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar canciones, artistas...',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                  prefixIcon: const Icon(Icons.search, color: Colors.white),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchResults = [];
                              _hasSearched = false;
                            });
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppTheme.surface.withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(color: AppTheme.primaryLight, width: 2),
                  ),
                ),
                onSubmitted: (value) => _performSearch(value),
                onChanged: (value) {
                  setState(() {});
                },
              ),
            ),
            
            // Content
            Expanded(
              child: _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isSearching) {
      return Center(
        child: CircularProgressIndicator(color: AppTheme.primaryLight),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.withValues(alpha: 0.7)),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_rounded, size: 80, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              'Busca tu música favorita',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Escribe el nombre de la canción o artista',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note_outlined, size: 64, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              'No se encontraron resultados',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        return _SearchResultTile(
          result: result,
          onAdd: () => _addToPlaylist(result),
        );
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final YouTubeSearchResult result;
  final VoidCallback onAdd;

  const _SearchResultTile({
    required this.result,
    required this.onAdd,
  });

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              AppTheme.surface.withValues(alpha: 0.9),
              AppTheme.surfaceLight.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    result.thumbnailUrl,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 80,
                        height: 80,
                        color: AppTheme.surface,
                        child: Icon(
                          Icons.music_note,
                          color: Colors.white.withValues(alpha: 0.3),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        result.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(result.duration),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                // Add to playlist button only (streaming disabled)
                IconButton(
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: AppTheme.primaryLight,
                    size: 32,
                  ),
                  onPressed: onAdd,
                  tooltip: 'Añadir a playlist',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectPlaylistDialog extends StatelessWidget {
  final List playlists;

  const _SelectPlaylistDialog({required this.playlists});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Seleccionar Playlist',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            return ListTile(
              title: Text(
                playlist.name,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(context, playlist.id),
            );
          },
        ),
      ),
    );
  }
}