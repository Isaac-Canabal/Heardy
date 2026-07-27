import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../services/audio_player_handler.dart';
import '../services/repair_service.dart';
import '../services/log_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<String> _calculateStorageUsage() async {
    try {
      final songs = await DatabaseHelper.instance.getSongs();
      int totalBytes = 0;
      
      for (final song in songs) {
        try {
          final audioFile = File(song.filePath);
          if (await audioFile.exists()) {
            totalBytes += await audioFile.length();
          }
        } catch (_) {}
        
        try {
          if (song.artPath.isNotEmpty) {
            final artFile = File(song.artPath);
            if (await artFile.exists()) {
              totalBytes += await artFile.length();
            }
          }
        } catch (_) {}
      }
      
      return _formatBytes(totalBytes);
    } catch (e) {
      return 'Error calculando';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final musicProvider = Provider.of<MusicProvider>(context);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
        children: [
          const Text(
            'Ajustes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 24),
          _SectionTitle('Almacenamiento'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<String>(
              future: _calculateStorageUsage(),
              builder: (context, snapshot) {
                final storage = snapshot.data ?? 'Calculando...';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.storage_rounded,
                          color: AppTheme.primaryLight,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Espacio usado',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      storage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Total de canciones descargadas',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 28),
          const _StatisticsSection(),
          const SizedBox(height: 28),
          _SectionTitle('Apariencia'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tema de color',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                ...AppThemePreset.values.map((preset) {
                  final selected = settings.preset == preset;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => settings.setPreset(preset),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              _PresetDot(preset: preset),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  settings.presetLabel(preset),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (selected)
                                Icon(Icons.check_circle_rounded,
                                    color: AppTheme.primaryLight, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle('Orden de playlists'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            child: musicProvider.playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Crea playlists para poder reordenarlas aquí.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: musicProvider.playlists.length,
                    onReorder: (oldIndex, newIndex) async {
                      if (newIndex > oldIndex) newIndex--;
                      final list = [...musicProvider.playlists];
                      final item = list.removeAt(oldIndex);
                      list.insert(newIndex, item);
                      await musicProvider.reorderPlaylists(list);
                    },
                    itemBuilder: (context, index) {
                      final p = musicProvider.playlists[index];
                      return ListTile(
                        key: ValueKey(p.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                        title: Text(
                          p.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Text(
                          '#${index + 1}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 28),
          _SectionTitle('Mantenimiento'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.build_rounded,
                      color: AppTheme.primaryLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Reparar reproductor',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Usa esto si el audio deja de reproducirse. Reinicia el estado del reproductor sin perder tus canciones.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary.withValues(alpha: 0.3),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reparar', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: AppTheme.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          title: const Text('Reparar Reproductor', style: TextStyle(color: Colors.white)),
                          content: const Text(
                            '¿Deseas realizar una reparación completa? Esto incluirá:\n\n• Verificar archivos corruptos\n• Limpiar archivos temporales\n• Verificar base de datos\n• Reiniciar el reproductor\n\nLa reproducción actual se detendrá.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text('Cancelar', style: TextStyle(color: Colors.white.withAlpha(128))),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text('Reparar', style: TextStyle(color: AppTheme.primaryLight, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true && context.mounted) {
                        // Mostrar diálogo de progreso
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: AppTheme.surface,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: AppTheme.primaryLight),
                                SizedBox(height: 16),
                                Text('Reparando...', style: TextStyle(color: Colors.white)),
                                SizedBox(height: 8),
                                Text('Esto puede tomar unos segundos', style: TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                          ),
                        );
                        
                        final audioHandler = Provider.of<AudioPlayerHandler>(context, listen: false);
                        final result = await RepairService.performFullRepair(
                          audioHandler: audioHandler,
                          musicProvider: musicProvider,
                        );
                        
                        if (context.mounted) {
                          Navigator.pop(context); // Cerrar diálogo de progreso
                          
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(result.getUserMessage()),
                              backgroundColor: result.hasErrors 
                                  ? Colors.red.withValues(alpha: 0.8)
                                  : result.hasWarnings
                                      ? Colors.orange.withValues(alpha: 0.8)
                                      : AppTheme.surface,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.withValues(alpha: 0.15),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.bug_report_rounded, size: 18, color: Colors.redAccent),
                    label: const Text('Ver Log de Errores', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () async {
                      final logs = await LogService.readLogs();
                      if (context.mounted) {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: AppTheme.surface,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Log de Errores', style: TextStyle(color: Colors.white)),
                                IconButton(
                                  icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
                                  onPressed: () async {
                                    await LogService.clearLogs();
                                    if (ctx.mounted) Navigator.pop(ctx);
                                  },
                                ),
                              ],
                            ),
                            content: SizedBox(
                              width: double.maxFinite,
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  logs,
                                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Cerrar', style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle('Búsqueda'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: AppTheme.primaryLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Resultados máximos',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Número de resultados a mostrar en búsquedas (10-100)',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, size: 20),
                      color: AppTheme.primaryLight,
                      onPressed: settings.maxSearchResults > 10
                          ? () => settings.setMaxSearchResults(settings.maxSearchResults - 10)
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        '${settings.maxSearchResults}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      color: AppTheme.primaryLight,
                      onPressed: settings.maxSearchResults < 100
                          ? () => settings.setMaxSearchResults(settings.maxSearchResults + 10)
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle('Acerca de'),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Heardy',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Reproductor y descargador offline de música desde YouTube.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatisticsData {
  final int totalPlays;
  final int totalListenSeconds;
  final String? topArtist;
  final int topArtistPlays;
  final List<Map<String, dynamic>> topSongs;

  const _StatisticsData({
    required this.totalPlays,
    required this.totalListenSeconds,
    this.topArtist,
    required this.topArtistPlays,
    required this.topSongs,
  });
}

class _StatisticsSection extends StatefulWidget {
  const _StatisticsSection();

  @override
  State<_StatisticsSection> createState() => _StatisticsSectionState();
}

class _StatisticsSectionState extends State<_StatisticsSection> {
  bool _isWeek = true;
  bool _isExpanded = false;

  Future<_StatisticsData> _loadStatistics(bool isWeek) async {
    final db = DatabaseHelper.instance;
    final results = await Future.wait([
      isWeek ? db.getTotalPlaysThisWeek() : db.getTotalPlaysThisMonth(),
      isWeek ? db.getTotalListenTimeThisWeek() : db.getTotalListenTimeThisMonth(),
      isWeek ? db.getTopArtistThisWeek() : db.getTopArtistThisMonth(),
      isWeek ? db.getTopSongsThisWeek(limit: 10) : db.getTopSongsThisMonth(limit: 10),
    ]);

    final topArtist = results[2] as Map<String, dynamic>?;
    return _StatisticsData(
      totalPlays: results[0] as int,
      totalListenSeconds: results[1] as int,
      topArtist: topArtist?['artist'] as String?,
      topArtistPlays: topArtist?['playCount'] as int? ?? 0,
      topSongs: results[3] as List<Map<String, dynamic>>,
    );
  }

  String _formatListenTime(int totalSeconds) {
    if (totalSeconds < 60) return '$totalSeconds s';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Estadísticas'),
        const SizedBox(height: 10),
        Container(
          decoration: AppTheme.glassCard(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.bar_chart_rounded,
                    color: AppTheme.primaryLight,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Tu actividad',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  _PeriodToggle(
                    isWeek: _isWeek,
                    onChanged: (isWeek) => setState(() {
                      _isWeek = isWeek;
                      _isExpanded = false; // Reset on period change
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FutureBuilder<_StatisticsData>(
                future: _loadStatistics(_isWeek),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }

                  final data = snapshot.data;
                  if (data == null || (data.totalPlays == 0 && data.topSongs.isEmpty)) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Reproduce música para ver tus estadísticas.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _StatMiniCard(
                              label: 'Reproducciones',
                              value: '${data.totalPlays}',
                              icon: Icons.play_circle_outline_rounded,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _StatMiniCard(
                              label: 'Tiempo escuchado',
                              value: _formatListenTime(data.totalListenSeconds),
                              icon: Icons.schedule_rounded,
                            ),
                          ),
                        ],
                      ),
                      if (data.topArtist != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Artista más escuchado',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.person_rounded,
                              color: AppTheme.primaryLight,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                data.topArtist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${data.topArtistPlays}x',
                                style: TextStyle(
                                  color: AppTheme.primaryLight,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (data.topSongs.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Top canciones',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...List.generate(
                          _isExpanded ? data.topSongs.length : (data.topSongs.length > 5 ? 5 : data.topSongs.length), 
                          (index) {
                            final song = data.topSongs[index];
                            return _TopSongRow(
                              rank: index + 1,
                              title: song['title'] as String? ?? 'Sin título',
                              artist: song['artist'] as String? ?? 'Desconocido',
                              artPath: song['artPath'] as String? ?? '',
                              playCount: song['playCount'] as int? ?? 0,
                            );
                          }
                        ),
                        if (data.topSongs.length > 5)
                          Center(
                            child: IconButton(
                              icon: Icon(
                                _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                              onPressed: () {
                                setState(() {
                                  _isExpanded = !_isExpanded;
                                });
                              },
                            ),
                          ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PeriodToggle extends StatelessWidget {
  final bool isWeek;
  final ValueChanged<bool> onChanged;

  const _PeriodToggle({
    required this.isWeek,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PeriodChip(
            label: 'Semana',
            selected: isWeek,
            onTap: () => onChanged(true),
          ),
          _PeriodChip(
            label: 'Mes',
            selected: !isWeek,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTheme.primary.withValues(alpha: 0.35)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatMiniCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.primaryLight, size: 18),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _TopSongRow extends StatelessWidget {
  final int rank;
  final String title;
  final String artist;
  final String artPath;
  final int playCount;

  const _TopSongRow({
    required this.rank,
    required this.title,
    required this.artist,
    required this.artPath,
    required this.playCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _buildArt(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${playCount}x',
              style: TextStyle(
                color: AppTheme.primaryLight,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArt() {
    if (artPath.isNotEmpty) {
      final file = File(artPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderArt(),
        );
      }
    }
    return _placeholderArt();
  }

  Widget _placeholderArt() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.7),
        size: 20,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.primaryLight.withValues(alpha: 0.95),
        fontWeight: FontWeight.w700,
        fontSize: 14,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _PresetDot extends StatelessWidget {
  final AppThemePreset preset;
  const _PresetDot({required this.preset});

  @override
  Widget build(BuildContext context) {
    final colors = switch (preset) {
      AppThemePreset.navy => [const Color(0xFF2563EB), const Color(0xFF1E40AF)],
      AppThemePreset.violet => [const Color(0xFF7C3AED), const Color(0xFF4F46E5)],
      AppThemePreset.rose => [const Color(0xFFDB2777), const Color(0xFFBE185D)],
    };
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: colors),
      ),
    );
  }
}
