import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../theme/app_theme.dart';
import '../widgets/playlist_target_sheet.dart';
import '../widgets/song_tile.dart';

/// Local o remoto: qué colección está mirando la pestaña de búsqueda.
enum _SearchScope { local, youtube }

/// Búsqueda con dos pestañas: local (sobre la biblioteca ya indexada, sin
/// red) y YouTube (vía [DownloadSource], para descargar sin tener que pegar
/// una URL). La pestaña local es la que recicló la vieja pantalla de
/// búsqueda de YouTube cuando se podó la capa de descarga (Etapa 5) — filtra
/// en cliente porque una colección personal no necesita paginación ni ida y
/// vuelta a la red.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<Song> _allSongs = [];
  String _query = '';
  bool _loading = true;
  // -1 so the very first build (version starts at 0 in MusicProvider)
  // triggers the initial load too — one mechanism for both "first open"
  // and "reload after a scan", instead of an initState that only ever
  // saw whatever existed at cold start (IndexedStack keeps this screen
  // alive, so initState never runs again).
  int _loadedVersion = -1;

  _SearchScope _scope = _SearchScope.local;
  Timer? _debounce;
  List<RemoteTrack> _youtubeResults = [];
  bool _youtubeLoading = false;
  String? _youtubeError;
  // Descarta una respuesta que llega tarde de una búsqueda ya superada por
  // una más nueva — sin esto, escribir rápido puede hacer que el resultado
  // de la letra "b" pise al de "bon" si "b" tarda más en volver.
  int _searchGeneration = 0;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final songs = await DatabaseHelper.instance.getSongs();
    if (!mounted) return;
    setState(() {
      _allSongs = songs.where((s) => !s.missing).toList();
      _loading = false;
    });
  }

  List<Song> _matches(int maxResults) {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    final matches = _allSongs
        .where((s) => s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q))
        .toList();
    return matches.length > maxResults ? matches.sublist(0, maxResults) : matches;
  }

  Future<void> _play(Song song, List<Song> results) async {
    final audioHandler = context.read<AudioPlayerHandler>();
    await context.read<MusicProvider>().playSearchResults(results, song, audioHandler);
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim());
    if (_scope == _SearchScope.youtube) _scheduleYoutubeSearch();
  }

  void _switchScope(_SearchScope scope) {
    setState(() => _scope = scope);
    if (scope == _SearchScope.youtube && _query.isNotEmpty && _youtubeResults.isEmpty) {
      _scheduleYoutubeSearch();
    }
  }

  void _scheduleYoutubeSearch() {
    _debounce?.cancel();
    if (_query.isEmpty) {
      setState(() {
        _youtubeResults = [];
        _youtubeError = null;
        _youtubeLoading = false;
      });
      return;
    }
    // Espera a que el usuario deje de escribir en vez de buscar en cada
    // pulsación — cada búsqueda es una petición real al servidor.
    _debounce = Timer(const Duration(milliseconds: 500), _runYoutubeSearch);
  }

  Future<void> _runYoutubeSearch() async {
    final query = _query;
    final generation = ++_searchGeneration;
    setState(() {
      _youtubeLoading = true;
      _youtubeError = null;
    });
    try {
      final maxResults = context.read<SettingsProvider>().maxSearchResults;
      final results = await context.read<DownloadSource>().search(query, limit: maxResults);
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _youtubeResults = results);
    } on DownloadSourceException catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _youtubeError = e.userMessage);
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _youtubeError = 'No se pudo buscar: $e');
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _youtubeLoading = false);
      }
    }
  }

  Future<void> _downloadYoutubeResult(RemoteTrack track) async {
    final choice = await pickTargetPlaylist(context);
    if (choice == null || !mounted) return;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;

    final provider = context.read<DownloadProvider>();
    final added = await provider.enqueueTrack(
      track,
      playlistId: playlistId,
      // Viene de /search (extract_flat): `artist` es el nombre del canal,
      // no el artista real. metadataComplete=false hace que el worker pida
      // /resolve antes de bajar nada (DD6) — el mismo mecanismo que ya usan
      // las entradas de playlist, sin duplicar la lógica de resolución acá.
      metadataComplete: false,
    );
    if (!mounted) return;
    provider.processQueue();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '"${track.title}" agregada a la cola' : 'Esa canción ya estaba en la cola'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxResults = context.watch<SettingsProvider>().maxSearchResults;
    final audioHandler = context.watch<AudioPlayerHandler>();
    final libraryVersion = context.watch<MusicProvider>().librarySongsVersion;
    if (_loadedVersion != libraryVersion) {
      _loadedVersion = libraryVersion;
      _load();
    }
    final results = _matches(maxResults);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Buscar',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: SegmentedButton<_SearchScope>(
              segments: const [
                ButtonSegment(
                  value: _SearchScope.local,
                  icon: Icon(Icons.folder_rounded, size: 16),
                  label: Text('Mi biblioteca'),
                ),
                ButtonSegment(
                  value: _SearchScope.youtube,
                  icon: Icon(Icons.cloud_rounded, size: 16),
                  label: Text('YouTube'),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (selection) => _switchScope(selection.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: TextField(
              key: const Key('search_field'),
              controller: _controller,
              onChanged: _onQueryChanged,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _scope == _SearchScope.local ? 'Buscar en tu biblioteca' : 'Buscar en YouTube',
                prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primaryLight),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          Expanded(
            child: _scope == _SearchScope.local
                ? (_loading ? const Center(child: CircularProgressIndicator()) : _buildLocalContent(results, audioHandler))
                : _buildYoutubeContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalContent(List<Song> results, AudioPlayerHandler audioHandler) {
    if (_query.isEmpty) {
      return _buildHint(Icons.search_rounded, 'Buscá tu música', 'Escribí el título o el artista');
    }
    if (results.isEmpty) {
      return _buildHint(Icons.music_note_outlined, 'Sin resultados', 'No encontramos nada con "$_query"');
    }
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final currentId = snapshot.data?.id;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 90),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final song = results[index];
            return SongTile(
              song: song,
              isPlaying: song.id == currentId,
              onTap: () => _play(song, results),
            );
          },
        );
      },
    );
  }

  Widget _buildYoutubeContent() {
    if (!context.watch<SettingsProvider>().hasDownloadServer) {
      return _buildHint(
        Icons.dns_outlined,
        'No hay servidor de descargas configurado',
        'Configuralo en Ajustes → Servidor de descargas',
      );
    }
    if (_query.isEmpty) {
      return _buildHint(Icons.cloud_outlined, 'Buscá en YouTube', 'Escribí para buscar sin salir de la app');
    }
    if (_youtubeLoading && _youtubeResults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_youtubeError != null) {
      return _buildHint(Icons.error_outline_rounded, 'No se pudo buscar', _youtubeError!);
    }
    if (_youtubeResults.isEmpty) {
      return _buildHint(Icons.music_note_outlined, 'Sin resultados', 'No encontramos nada con "$_query"');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _youtubeResults.length,
      itemBuilder: (context, index) => _YoutubeResultTile(
        track: _youtubeResults[index],
        onDownload: () => _downloadYoutubeResult(_youtubeResults[index]),
      ),
    );
  }

  Widget _buildHint(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _YoutubeResultTile extends StatelessWidget {
  final RemoteTrack track;
  final VoidCallback onDownload;

  const _YoutubeResultTile({required this.track, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: AppTheme.glassCard(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onDownload,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: track.thumbnailUrl.isEmpty
                      ? _placeholder()
                      : Image.network(
                          track.thumbnailUrl,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (track.durationSeconds > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      _formatTrackDuration(track.durationSeconds),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
                    ),
                  ),
                Icon(Icons.download_rounded, color: AppTheme.primaryLight, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // mm:ss, no "AppTheme.formatDuration" — ese está pensado para la duración
  // TOTAL de una playlist ("3h 20m"), no para una pista suelta.
  String _formatTrackDuration(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  Widget _placeholder() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(track.title)),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
  }
}
