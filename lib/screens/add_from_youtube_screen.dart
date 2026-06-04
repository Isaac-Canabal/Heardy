import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_progress_card.dart';
import '../widgets/glass_card.dart';
import 'package:uuid/uuid.dart';

class AddFromYouTubeScreen extends StatefulWidget {
  final bool embedInShell;

  const AddFromYouTubeScreen({super.key, this.embedInShell = false});

  @override
  State<AddFromYouTubeScreen> createState() => _AddFromYouTubeScreenState();
}

class _AddFromYouTubeScreenState extends State<AddFromYouTubeScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _newPlaylistController = TextEditingController();
  final YoutubeService _ytService = YoutubeService();

  bool _isAnalyzing = false;
  bool _isPlaylist = false;
  bool _hasAnalyzed = false;

  String _videoTitle = '';
  String _videoArtist = '';
  String _videoThumbnail = '';

  int _playlistCount = 0;
  List<String> _playlistPreviewTitles = [];

  String? _selectedPlaylistId;
  bool _createNewPlaylist = false;

  @override
  void dispose() {
    _urlController.dispose();
    _newPlaylistController.dispose();
    _ytService.dispose();
    super.dispose();
  }

  Future<void> _analyzeUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnackBar("Por favor ingresa una URL de YouTube", isError: true);
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _hasAnalyzed = false;
      _isPlaylist = false;
    });

    try {
      if (url.contains("list=")) {
        _isPlaylist = true;
        final videoIds = await _ytService.getPlaylistVideoIds(url);
        _playlistCount = videoIds.length;

        if (videoIds.isNotEmpty) {
          final firstInfo = await _ytService.getVideoInfo(
            'https://www.youtube.com/watch?v=${videoIds.first}',
          );
          _playlistPreviewTitles = [firstInfo['title'] as String];
          if (videoIds.length > 1) {
            _playlistPreviewTitles.add(
              "Y ${videoIds.length - 1} videos más...",
            );
          }
        }

        setState(() {
          _hasAnalyzed = true;
          _isAnalyzing = false;
        });
      } else {
        final info = await _ytService.getVideoInfo(url);
        setState(() {
          _videoTitle = info['title'] as String;
          _videoArtist = info['artist'] as String;
          _videoThumbnail = info['thumbnailUrl'] as String;
          _isPlaylist = false;
          _hasAnalyzed = true;
          _isAnalyzing = false;
        });
      }
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
      });
      _showSnackBar(
        "Error al analizar la URL. Verifica que sea correcta.",
        isError: true,
      );
    }
  }

  Future<void> _startDownload() async {
    final musicProvider = Provider.of<MusicProvider>(context, listen: false);
    final downloadProvider = Provider.of<DownloadProvider>(
      context,
      listen: false,
    );
    final url = _urlController.text.trim();

    String? targetId = _selectedPlaylistId;

    if (_createNewPlaylist) {
      final name = _newPlaylistController.text.trim();
      if (name.isEmpty) {
        _showSnackBar(
          "Por favor ingresa un nombre para la nueva lista",
          isError: true,
        );
        return;
      }
      final newId = const Uuid().v4();
      await musicProvider.createPlaylistWithId(newId, name);
      targetId = newId;
    }

    if (targetId == null) {
      _showSnackBar(
        "Por favor selecciona o crea una lista de reproducción",
        isError: true,
      );
      return;
    }

    try {
      if (_isPlaylist) {
        await downloadProvider.downloadPlaylist(url, targetId);
      } else {
        await downloadProvider.downloadVideo(url, targetId);
      }

      if (downloadProvider.errorMessage != null) {
        _showSnackBar(downloadProvider.errorMessage!, isError: true);
        downloadProvider.clearError();
        return;
      }

      await musicProvider.loadPlaylists();

      if (downloadProvider.isDownloading) {
        _showSnackBar(
          downloadProvider.statusMessage.isNotEmpty
              ? downloadProvider.statusMessage
              : 'Descarga iniciada. Sigue el progreso abajo.',
        );
        return;
      }

      final message = downloadProvider.statusMessage.isNotEmpty
          ? downloadProvider.statusMessage
          : 'Operación completada.';
      _showSnackBar(message, isSuccess: true);
      
      // Delay navigation to ensure UI is fully refreshed
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _showSnackBar("Error en la descarga: $e", isError: true);
    }
  }

  void _showSnackBar(
    String message, {
    bool isError = false,
    bool isSuccess = false,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.redAccent.shade700
            : isSuccess
                ? const Color(0xFF059669)
                : AppTheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<SettingsProvider>(context);
    final musicProvider = Provider.of<MusicProvider>(context);
    final downloadProvider = Provider.of<DownloadProvider>(context);
    final playlists = musicProvider.playlists;

    if (playlists.isNotEmpty &&
        _selectedPlaylistId == null &&
        !_createNewPlaylist) {
      _selectedPlaylistId = playlists.first.id;
    }

    return Scaffold(
      extendBodyBehindAppBar: !widget.embedInShell,
      appBar: widget.embedInShell
          ? null
          : AppBar(
              title: const Text('Añadir desde YouTube'),
              flexibleSpace: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppTheme.backgroundTop.withValues(alpha: 0.95),
                      AppTheme.backgroundTop.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.embedInShell ? 16 : 8,
              16,
              widget.embedInShell ? 90 : 24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.embedInShell)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Descargas',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                _buildHeroBanner(),
                const SizedBox(height: 20),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sectionLabel('Enlace de YouTube', Icons.link_rounded),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _urlController,
                        enabled: !_isAnalyzing && !downloadProvider.isDownloading,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'https://www.youtube.com/watch?v=...',
                          prefixIcon: Icon(Icons.link_rounded, color: AppTheme.primaryLight),
                        ),
                      ),
                      const SizedBox(height: 16),
                      AppTheme.gradientButton(
                        onPressed: _isAnalyzing || downloadProvider.isDownloading
                            ? null
                            : _analyzeUrl,
                        child: _isAnalyzing
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Text(
                                'Analizar Enlace',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_hasAnalyzed)
                  GlassCard(
                    child: _isPlaylist
                        ? _buildPlaylistPreview()
                        : _buildVideoPreview(),
                  ),
                if (_hasAnalyzed) const SizedBox(height: 16),
                if (_hasAnalyzed)
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sectionLabel('Destino', Icons.folder_special_rounded),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Checkbox(
                              value: _createNewPlaylist,
                              onChanged: _isAnalyzing || downloadProvider.isDownloading
                                  ? null
                                  : (val) {
                                      setState(() {
                                        _createNewPlaylist = val ?? false;
                                      });
                                    },
                            ),
                            const Expanded(
                              child: Text(
                                'Crear una nueva lista',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _createNewPlaylist
                            ? TextField(
                                controller: _newPlaylistController,
                                enabled: !_isAnalyzing && !downloadProvider.isDownloading,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  hintText: 'Nombre de la nueva lista',
                                ),
                              )
                            : playlists.isEmpty
                                ? Text(
                                    'No tienes listas. Marca la casilla para crear una.',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.5),
                                      fontSize: 13,
                                    ),
                                  )
                                : Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0E0C18),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _selectedPlaylistId,
                                        dropdownColor: AppTheme.surface,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                        ),
                                        iconEnabledColor: AppTheme.primaryLight,
                                        isExpanded: true,
                                        items: playlists.map((p) {
                                          return DropdownMenuItem(
                                            value: p.id,
                                            child: Text(p.name),
                                          );
                                        }).toList(),
                                        onChanged: _isAnalyzing || downloadProvider.isDownloading
                                            ? null
                                            : (val) {
                                                setState(() {
                                                  _selectedPlaylistId = val;
                                                });
                                              },
                                      ),
                                    ),
                                  ),
                        const SizedBox(height: 20),
                        AppTheme.gradientButton(
                          onPressed: downloadProvider.isDownloading
                              ? null
                              : _startDownload,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.download_rounded, color: Colors.white),
                              SizedBox(width: 8),
                              Text(
                                'Descargar e Importar',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                if (downloadProvider.isDownloading)
                  DownloadProgressCard(
                    progress: downloadProvider.progress,
                    statusMessage: downloadProvider.statusMessage,
                    currentTitle: downloadProvider.currentTitle,
                    elapsed: downloadProvider.downloadElapsed,
                    onCancel: () => downloadProvider.cancelAllDownloads(),
                  ),
                if (downloadProvider.errorMessage != null &&
                    !downloadProvider.isDownloading)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: GlassCard(
                      highlighted: true,
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: Colors.redAccent.shade100,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              downloadProvider.errorMessage!,
                              style: TextStyle(
                                color: Colors.redAccent.shade100,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroBanner() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accentPink.withValues(alpha: 0.85),
            AppTheme.primary.withValues(alpha: 0.9),
            AppTheme.accent.withValues(alpha: 0.85),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.play_circle_filled_rounded,
              color: Colors.white,
              size: 36,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Importa tu música',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Descarga videos y playlists para escuchar sin conexión.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primaryLight, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPreview() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_videoThumbnail.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                _videoThumbnail,
                width: 96,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 96,
                  height: 64,
                  color: AppTheme.surfaceLight,
                  child: const Icon(Icons.broken_image, color: Colors.white24),
                ),
              ),
            ),
          ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'VIDEO DETECTADO',
                style: TextStyle(
                  color: AppTheme.accent.withValues(alpha: 0.95),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _videoTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _videoArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PLAYLIST DETECTADA',
          style: TextStyle(
            color: AppTheme.accent.withValues(alpha: 0.95),
            fontWeight: FontWeight.w800,
            fontSize: 11,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Contiene $_playlistCount videos',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 8),
        ..._playlistPreviewTitles.map(
          (t) => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '• $t',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
