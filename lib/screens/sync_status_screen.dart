import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../build_marker.dart';
import '../models/playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../services/cloud_restore_match.dart';
import '../services/cloud_source.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/library_diff.dart';
import '../theme/app_theme.dart';

enum _Phase { loading, error, noCloudLibrary, upToDate, matching, review, enqueuing, done }

/// "El PC sabe qué le falta" (W6) + restaurarlo (W7) — la estrategia híbrida
/// de la Etapa 16 E-2: compara el índice de la nube contra el hash de audio
/// de lo que ya hay en este equipo, busca en YouTube un equivalente de cada
/// canción que falta (mismo criterio que el emparejamiento de Spotify: por
/// duración, nunca por texto), enseña el resultado una sola vez, y sólo al
/// confirmar recrea las playlists de la nube que no existan acá y encola las
/// descargas — nunca antes.
class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  int _cloudTotal = 0;
  String? _accountEmail;

  List<Map<String, dynamic>> _cloudPlaylists = const [];
  List<Map<String, dynamic>> _cloudPlaylistSongs = const [];

  // playlistId de la nube (o null = suelta, sin playlist) -> matches.
  Map<String?, List<CloudSongMatch>> _matchesByPlaylist = const {};
  int _matchedCount = 0;
  int _totalToMatch = 0;

  int _enqueuedCount = 0;

  bool _restoringHistory = false;
  String? _historyResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final cloudSource = context.read<CloudSource>();

      // Antes de asumir "no hay nada": `hasLibrary` distingue "el servidor
      // nunca recibió un push de ningún dispositivo para esta cuenta" (lo
      // más probable si esto es lo primero que se prueba en un equipo
      // nuevo) de "sincronizó y de verdad no hay nada". Mismo motivo por el
      // que un `[]` de la nube no debía leerse a ciegas como "está todo al
      // día" sin mirar esto primero.
      final account = await cloudSource.getAccount();
      if (!mounted) return;
      _accountEmail = context.read<HeardyAuthProvider>().email ??
          (account.username != null ? '@${account.username}' : account.identity);
      if (!account.hasLibrary) {
        setState(() => _phase = _Phase.noCloudLibrary);
        return;
      }

      final library = await cloudSource.getLibrary();
      final localHashes = await DatabaseHelper.instance.getLocalFileHashes();
      final cloudSongs = library?.songs ?? const [];
      final missing = missingCloudSongs(cloudSongs, localHashes);
      if (!mounted) return;

      _cloudTotal = cloudSongs.length;
      _cloudPlaylists = library?.playlists ?? const [];
      _cloudPlaylistSongs = library?.playlistSongs ?? const [];

      if (missing.isEmpty) {
        setState(() => _phase = _Phase.upToDate);
        return;
      }

      await _matchMissingSongs(missing);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo comparar la biblioteca: $e';
        _phase = _Phase.error;
      });
    }
  }

  /// Busca en YouTube un equivalente de cada canción que falta, una por una
  /// — mismo patrón secuencial que el análisis de una playlist de Spotify en
  /// `ImportScreen`, con el mismo motivo: mostrar progreso real en vez de
  /// congelar la pantalla durante N búsquedas.
  Future<void> _matchMissingSongs(List<Map<String, dynamic>> missing) async {
    setState(() {
      _phase = _Phase.matching;
      _matchedCount = 0;
      _totalToMatch = missing.length;
    });

    final source = context.read<DownloadSource>();
    final grouped = groupMissingSongsByPlaylist(missing, _cloudPlaylistSongs);
    final matchesByPlaylist = <String?, List<CloudSongMatch>>{};

    for (final entry in grouped.entries) {
      final matches = <CloudSongMatch>[];
      for (final song in entry.value) {
        matches.add(await matchCloudSong(song, source));
        if (!mounted) return;
        setState(() => _matchedCount++);
      }
      matchesByPlaylist[entry.key] = matches;
    }

    if (!mounted) return;
    setState(() {
      _matchesByPlaylist = matchesByPlaylist;
      _phase = _Phase.review;
    });
  }

  int get _acceptableCount => _matchesByPlaylist.values
      .expand((list) => list)
      .where((m) => m.isAcceptable)
      .length;

  Future<void> _confirmRestore() async {
    setState(() => _phase = _Phase.enqueuing);

    final musicProvider = context.read<MusicProvider>();
    final downloadProvider = context.read<DownloadProvider>();
    final playlistNameById = {
      for (final p in _cloudPlaylists)
        p['playlistId'] as String: (p['name'] as String?) ?? '',
    };
    final existingLocalIds = musicProvider.playlists.map((p) => p.id).toSet();

    var enqueued = 0;
    for (final entry in _matchesByPlaylist.entries) {
      final cloudPlaylistId = entry.key;
      final acceptable = entry.value.where((m) => m.isAcceptable).toList();
      if (acceptable.isEmpty) continue;

      // Sin playlist en la nube (suelta): la cola de descargas exige un
      // playlistId real (D6/W7), así que estas quedan fuera de la
      // restauración automática — el usuario las busca a mano si las quiere.
      if (cloudPlaylistId == null) continue;

      // Mismo id que en la nube a propósito: si esta playlist ya existe acá
      // (porque el usuario la creó en este mismo equipo, o una restauración
      // anterior ya la trajo), esto no hace nada — `insertPlaylist` ignora
      // conflictos de id. Conservar el id evita duplicar la misma playlist
      // con dos identidades distintas entre dispositivos.
      if (!existingLocalIds.contains(cloudPlaylistId)) {
        await DatabaseHelper.instance.insertPlaylist(
          Playlist(
            id: cloudPlaylistId,
            name: playlistNameById[cloudPlaylistId] ?? 'Restaurada',
            creationDate: DateTime.now(),
          ),
        );
        existingLocalIds.add(cloudPlaylistId);
      }

      for (final match in acceptable) {
        final ok = await downloadProvider.enqueueTrack(
          match.youtubeTrack!,
          playlistId: cloudPlaylistId,
          sourceType: 'restore',
          // Un match por búsqueda viene de /search (extract_flat) y se
          // resuelve en el worker antes de bajar nada (mismo motivo que
          // Buscar y que la restauración de Spotify, DD6). Uno que salió del
          // enlace original ya pasó por un `resolve` completo: repetirlo
          // sería una petición gastada para nada.
          metadataComplete: match.isExactSource,
        );
        if (ok) enqueued++;
      }
    }

    await musicProvider.loadPlaylists();
    downloadProvider.processQueue();

    if (!mounted) return;
    setState(() {
      _enqueuedCount = enqueued;
      _phase = _Phase.done;
    });
  }

  /// Baja el historial de la cuenta y lo reinserta acá, página a página.
  /// Independiente de la biblioteca a propósito: el historial vive en la nube
  /// aunque el índice no (`push_history` es aditivo y nada salvo "borrar mis
  /// datos" lo toca), así que esto tiene sentido incluso cuando la
  /// comparación de arriba dice que no hay biblioteca que restaurar.
  Future<void> _restoreHistory() async {
    setState(() {
      _restoringHistory = true;
      _historyResult = null;
    });
    final cloudSource = context.read<CloudSource>();
    try {
      var restored = 0;
      var seen = 0;
      String? cursor;
      do {
        final page = await cloudSource.getHistory(cursor: cursor);
        seen += page.rows.length;
        restored += await DatabaseHelper.instance.insertRestoredPlays(page.rows);
        cursor = page.nextCursor;
      } while (cursor != null);

      if (!mounted) return;
      setState(() {
        // "Ya estaban" y "son de canciones que no tenés" se distinguen mal
        // entre sí y no aportan nada distinto al usuario; lo que importa es
        // que el servidor tenía datos y cuántos entraron.
        _historyResult = seen == 0
            ? 'Tu cuenta no tiene historial guardado en la nube.'
            : restored == 0
                ? 'Las $seen reproducciones de tu cuenta ya estaban acá (o son de canciones que este equipo no tiene).'
                : 'Se recuperaron $restored reproducciones de $seen.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _historyResult = 'No se pudo recuperar el historial: $e');
    } finally {
      if (mounted) setState(() => _restoringHistory = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Restaurar desde tu cuenta'),
        // TEMP: identificador de build — ver build_marker.dart.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'build $buildMarker',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ),
        ],
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case _Phase.error:
        return _buildMessage(_error!, retry: true);
      case _Phase.noCloudLibrary:
        return _buildMessage(
          'Tu cuenta (${_accountEmail ?? 'sin identificar'}) todavía no tiene ninguna biblioteca subida a la '
          'nube. Esto compara contra lo que ya subió otro dispositivo — andá a tu teléfono, Ajustes → Cuenta, '
          'y tocá "Sincronizar ahora" ahí primero.',
          retry: true,
        );
      case _Phase.upToDate:
        return _buildMessage(
          _cloudTotal == 0
              ? 'La biblioteca en la nube está vacía todavía.'
              : 'Ya tenés las $_cloudTotal canciones de tu cuenta en este equipo.',
        );
      case _Phase.matching:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: _totalToMatch == 0 ? null : _matchedCount / _totalToMatch,
                ),
                const SizedBox(height: 16),
                Text(
                  'Buscando en YouTube $_matchedCount de $_totalToMatch...',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        );
      case _Phase.review:
        return _buildReview();
      case _Phase.enqueuing:
        return const Center(child: CircularProgressIndicator());
      case _Phase.done:
        return _buildMessage(
          _enqueuedCount == 0
              ? 'No se encontró ninguna coincidencia aceptable.'
              : 'Se encolaron $_enqueuedCount canciones — mirá el progreso en Añadir.',
        );
    }
  }

  Widget _buildMessage(String text, {bool retry = false}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (retry) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Reintentar')),
            ],
            const Divider(height: 40, color: Colors.white12),
            _buildHistoryRestore(),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryRestore() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Tus reproducciones se suben a la cuenta aparte de la biblioteca, así que '
          'pueden seguir en la nube aunque este equipo las haya perdido.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          ),
          icon: _restoringHistory
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history_rounded, size: 18),
          onPressed: _restoringHistory ? null : _restoreHistory,
          label: const Text('Recuperar mi historial'),
        ),
        if (_historyResult != null) ...[
          const SizedBox(height: 12),
          Text(
            _historyResult!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildReview() {
    final acceptable = _acceptableCount;
    final totalMatched = _matchesByPlaylist.values.fold<int>(0, (n, l) => n + l.length);
    final skipped = totalMatched - acceptable;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            skipped == 0
                ? '$acceptable canciones encontradas.'
                : '$acceptable canciones encontradas — $skipped sin coincidencia aceptable, no se descargarán.',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final entry in _matchesByPlaylist.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    entry.key == null
                        ? 'Sin playlist (no se restauran automáticamente)'
                        : (_cloudPlaylists.firstWhere(
                              (p) => p['playlistId'] == entry.key,
                              orElse: () => const {'name': 'Playlist'},
                            )['name'] as String? ??
                            'Playlist'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final match in entry.value) _MatchRow(match: match),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: acceptable == 0 ? null : _confirmRestore,
                child: Text('Descargar $acceptable canciones'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MatchRow extends StatelessWidget {
  final CloudSongMatch match;
  const _MatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final (icon, color, subtitle) = switch (match) {
      CloudSongMatch(isExactSource: true) => (
          Icons.verified_rounded,
          Colors.greenAccent,
          '${match.artist} · enlace original',
        ),
      CloudSongMatch(isGoodMatch: true) => (
          Icons.check_circle_rounded,
          Colors.greenAccent,
          match.artist,
        ),
      CloudSongMatch(isAcceptable: true) => (
          Icons.check_circle_outline_rounded,
          Colors.orangeAccent,
          '${match.artist} · revisar duración (±${match.durationDiffSeconds}s)',
        ),
      _ => (
          Icons.cancel_outlined,
          Colors.white38,
          '${match.artist} · sin coincidencia, no se descargará',
        ),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(match.title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }
}
