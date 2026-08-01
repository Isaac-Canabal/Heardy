import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_source.dart';
import '../theme/app_theme.dart';
import '../widgets/download_progress_card.dart';

/// What a pasted URL turned out to be, once analyzed.
enum _UrlKind { video, playlist }

/// "Pegar URL → vista previa → elegir playlist → encolar", plus the live
/// queue underneath. This is the second way music enters the library —
/// downloads land in the same SAF folder and go through the same
/// [DatabaseHelper]/[LibraryScanService] path as anything the user copies in
/// by hand (see CLAUDE.md DD2/DD3).
///
/// Talks to the server **only** through [DownloadSource] (never FastAPI
/// directly) and to the queue only through [DownloadProvider] — this screen
/// has no idea a Python process exists.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _urlController = TextEditingController();
  bool _isAnalyzing = false;
  String? _errorMessage;
  _UrlKind? _analyzedKind;
  RemoteTrack? _analyzedTrack;
  RemotePlaylist? _analyzedPlaylist;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _clearAnalysis() {
    _analyzedKind = null;
    _analyzedTrack = null;
    _analyzedPlaylist = null;
    _errorMessage = null;
  }

  bool _looksLikePlaylist(String url) {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters['list'] != null;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _urlController.text = text;
    _urlController.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _analyze() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isAnalyzing = true;
      _clearAnalysis();
    });

    try {
      final source = context.read<DownloadSource>();
      if (_looksLikePlaylist(url)) {
        final playlist = await source.resolvePlaylist(url);
        if (!mounted) return;
        setState(() {
          _analyzedKind = _UrlKind.playlist;
          _analyzedPlaylist = playlist;
        });
      } else {
        final track = await source.resolve(url);
        if (!mounted) return;
        setState(() {
          _analyzedKind = _UrlKind.video;
          _analyzedTrack = track;
        });
      }
    } on DownloadSourceException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.userMessage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'No se pudo analizar el enlace: $e');
    } finally {
      // Un único punto de reset — la pantalla que reemplaza a ésta (la vieja
      // add_from_youtube_screen.dart) tenía un bug justo por resetear el
      // flag en cada `return` en vez de en un solo `finally`.
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<_PlaylistChoice?> _pickTargetPlaylist({String? suggestedName}) {
    final playlists = context.read<MusicProvider>().playlists;
    return showModalBottomSheet<_PlaylistChoice>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistTargetSheet(playlists: playlists, suggestedName: suggestedName),
    );
  }

  Future<String?> _resolveTargetPlaylistId(_PlaylistChoice choice) async {
    if (choice.existingPlaylistId != null) return choice.existingPlaylistId;
    final name = choice.newPlaylistName;
    if (name == null || name.isEmpty) return null;

    final id = const Uuid().v4();
    await context.read<MusicProvider>().createPlaylistWithId(id, name);
    return id;
  }

  Future<void> _downloadTrack(RemoteTrack track) async {
    final choice = await _pickTargetPlaylist();
    if (choice == null || !mounted) return;
    final playlistId = await _resolveTargetPlaylistId(choice);
    if (playlistId == null || !mounted) return;

    final provider = context.read<DownloadProvider>();
    final added = await provider.enqueueTrack(
      track,
      playlistId: playlistId,
      // Viene de /resolve — la vista previa YA es la metadata definitiva,
      // así que el worker no debe volver a resolverla (DD6).
      metadataComplete: true,
    );
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();
    provider.processQueue();

    _showSnack(added ? '"${track.title}" agregada a la cola' : 'Esa canción ya estaba en la cola');
  }

  Future<void> _downloadPlaylist(RemotePlaylist playlist) async {
    final choice = await _pickTargetPlaylist(suggestedName: playlist.name);
    if (choice == null || !mounted) return;

    // Si se crea una playlist nueva a partir de esta importación, guardamos
    // la URL de origen — es lo que activa "Actualizar desde YouTube" en
    // playlist_detail_screen.dart. Si el destino es una playlist YA
    // existente, no la tocamos: podría no ser de origen YouTube.
    final isNewPlaylist = choice.existingPlaylistId == null;
    final playlistId = await _resolveTargetPlaylistId(choice);
    if (playlistId == null || !mounted) return;
    if (isNewPlaylist && playlist.sourceUrl.isNotEmpty) {
      await context.read<MusicProvider>().updatePlaylistUrl(playlistId, playlist.sourceUrl);
    }

    final provider = context.read<DownloadProvider>();
    final added = await provider.enqueuePlaylist(playlist, playlistId: playlistId);
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();
    provider.processQueue();

    _showSnack('$added ${added == 1 ? "canción encolada" : "canciones encoladas"}');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final libraryRootUri = context.watch<MusicProvider>().libraryRootUri;

    if (!settings.hasDownloadServer) return _buildNoServerState();
    if (libraryRootUri == null) return _buildNoFolderState();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Añadir desde YouTube',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('import_url_field'),
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: (_) => _analyze(),
                    decoration: InputDecoration(
                      hintText: 'Pegá un enlace de YouTube…',
                      prefixIcon: Icon(Icons.link_rounded, color: AppTheme.primaryLight),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        tooltip: 'Pegar',
                        onPressed: _pasteFromClipboard,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Material(
                  key: const Key('analyze_button'),
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _isAnalyzing ? null : _analyze,
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: _isAnalyzing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
              children: [
                if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
                if (_analyzedKind == _UrlKind.video && _analyzedTrack != null)
                  _buildTrackPreview(_analyzedTrack!),
                if (_analyzedKind == _UrlKind.playlist && _analyzedPlaylist != null)
                  _buildPlaylistPreview(_analyzedPlaylist!),
                _buildQueueSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoServerState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text(
              'No hay servidor de descargas configurado',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Configuralo en Ajustes → Servidor de descargas.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoFolderState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_rounded, size: 56, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text(
              'Elegí primero una carpeta de biblioteca',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Las descargas se guardan ahí, igual que los archivos que importás a mano. Configuralo en Ajustes.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: Colors.red.shade100, fontSize: 13, height: 1.35)),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackPreview(RemoteTrack track) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Thumb(url: track.thumbnailUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppTheme.formatDuration(track.durationSeconds),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('download_track_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Descargar'),
              onPressed: () => _downloadTrack(track),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistPreview(RemotePlaylist playlist) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${playlist.entries.length} ${playlist.entries.length == 1 ? "video" : "videos"}',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('download_playlist_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: Text('Descargar ${playlist.entries.length} canciones'),
              onPressed: playlist.entries.isEmpty ? null : () => _downloadPlaylist(playlist),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueSection() {
    final provider = context.watch<DownloadProvider>();
    final current = provider.current;
    final pending = provider.queue.where((j) => current == null || j.queueId != current.queueId).toList();
    final failures = provider.failures;

    if (current == null && pending.isEmpty && failures.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: DownloadProgressCard(
              title: current.displayTitle,
              subtitle: current.artist,
              phaseLabel: provider.phaseLabel,
              progress: provider.progress,
              queueRemaining: pending.length,
              onCancel: () => provider.cancelJob(current.queueId),
              onCancelAll: provider.cancelAll,
            ),
          ),
        if (current == null && pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(
                  'En cola',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton(
                  onPressed: provider.cancelAll,
                  child: const Text('Cancelar todo'),
                ),
              ],
            ),
          ),
        ...pending.map((job) => _QueueItemRow(
              job: job,
              onCancel: () => provider.cancelJob(job.queueId),
            )),
        if (failures.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                'No se pudieron descargar',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(onPressed: provider.clearFailures, child: const Text('Descartar')),
            ],
          ),
          ...failures.map((f) => _FailureRow(failure: f)),
        ],
      ],
    );
  }
}

class _PlaylistChoice {
  final String? existingPlaylistId;
  final String? newPlaylistName;
  const _PlaylistChoice.existing(this.existingPlaylistId) : newPlaylistName = null;
  const _PlaylistChoice.newPlaylist(this.newPlaylistName) : existingPlaylistId = null;
}

/// Elegir UNA playlist destino, existente o nueva — a diferencia del selector
/// multi-select de la bandeja (que asigna canciones YA en la biblioteca a
/// varias playlists a la vez), una descarga va a un solo lugar porque
/// [DownloadService.download] toma un único `playlistId`.
class _PlaylistTargetSheet extends StatefulWidget {
  final List<Playlist> playlists;
  final String? suggestedName;

  const _PlaylistTargetSheet({required this.playlists, this.suggestedName});

  @override
  State<_PlaylistTargetSheet> createState() => _PlaylistTargetSheetState();
}

class _PlaylistTargetSheetState extends State<_PlaylistTargetSheet> {
  String? _selectedId;
  late final TextEditingController _newNameController;

  @override
  void initState() {
    super.initState();
    _newNameController = TextEditingController(text: widget.suggestedName ?? '');
  }

  @override
  void dispose() {
    _newNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final newName = _newNameController.text.trim();
    final canConfirm = _selectedId != null || newName.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '¿A qué playlist?',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            if (widget.playlists.isNotEmpty)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: widget.playlists.map((playlist) {
                    return RadioListTile<String>(
                      key: Key('playlist_radio_${playlist.id}'),
                      value: playlist.id,
                      groupValue: _selectedId,
                      onChanged: (value) => setState(() {
                        _selectedId = value;
                        _newNameController.clear();
                      }),
                      activeColor: AppTheme.primary,
                      title: Text(playlist.name, style: const TextStyle(color: Colors.white)),
                    );
                  }).toList(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: TextField(
                key: const Key('new_playlist_name_field'),
                controller: _newNameController,
                onChanged: (_) => setState(() {
                  if (_newNameController.text.trim().isNotEmpty) _selectedId = null;
                }),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Crear nueva playlist…',
                  prefixIcon: Icon(Icons.add_rounded),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('confirm_playlist_choice'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: canConfirm
                      ? () => Navigator.pop(
                            context,
                            _selectedId != null
                                ? _PlaylistChoice.existing(_selectedId)
                                : _PlaylistChoice.newPlaylist(newName),
                          )
                      : null,
                  child: const Text('Confirmar'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueItemRow extends StatelessWidget {
  final DownloadJob job;
  final VoidCallback onCancel;

  const _QueueItemRow({required this.job, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: AppTheme.glassCard(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _Thumb(url: job.thumbnailUrl, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (job.artist.isNotEmpty)
                    Text(
                      job.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.4), size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureRow extends StatelessWidget {
  final DownloadFailure failure;
  const _FailureRow({required this.failure});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              failure.permanent ? Icons.block_rounded : Icons.wifi_off_rounded,
              color: Colors.redAccent.shade100,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    failure.message,
                    style: TextStyle(color: Colors.red.shade100, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String url;
  final double size;
  const _Thumb({required this.url, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final radius = size >= 48 ? 10.0 : 8.0;
    if (url.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: Icon(Icons.music_note_rounded, color: Colors.white70, size: size * 0.4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: Icon(Icons.music_note_rounded, color: Colors.white70, size: size * 0.4),
        ),
      ),
    );
  }
}
