import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';

/// Local search over the whole library — recycled from the old YouTube
/// search screen when the download layer was pruned (Stage 5). Filters
/// client-side: a personal collection, unlike a catalog, doesn't need
/// pagination or a network round trip.
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

  @override
  void dispose() {
    _controller.dispose();
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
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: TextField(
              controller: _controller,
              onChanged: (v) => setState(() => _query = v.trim()),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar en tu biblioteca',
                prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primaryLight),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(results, audioHandler),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<Song> results, AudioPlayerHandler audioHandler) {
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

  Widget _buildHint(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: Colors.white.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 13)),
        ],
      ),
    );
  }
}
