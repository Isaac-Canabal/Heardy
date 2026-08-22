import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../services/download_source.dart';
import '../services/storage_service.dart';
import '../services/ytdlp_server_source.dart';
import '../l10n/app_localizations.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// El audio real de las canciones importadas o descargadas vive en la
  /// carpeta SAF que eligió el usuario, no en un `File` que `dart:io` pueda
  /// leer (D1) — antes esto sólo sumaba `File(song.filePath)`, que para esas
  /// canciones está vacío, así que el número mostrado ignoraba casi todo lo
  /// que realmente ocupa espacio. Se suma aparte: el tamaño real de la
  /// carpeta (vía SAF) más lo que sigue siendo legítimamente un `File` —
  /// descargas heredadas pre-pivot y las miniaturas, que siempre viven en
  /// almacenamiento privado sin importar el origen de la canción (D5).
  Future<String> _calculateStorageUsage(BuildContext context, String? libraryRootUri) async {
    try {
      int totalBytes = 0;

      if (libraryRootUri != null) {
        totalBytes += await StorageService().calculateLibrarySize(libraryRootUri);
      }

      final songs = await DatabaseHelper.instance.getSongs();
      for (final song in songs) {
        if (song.uri == null || song.uri!.isEmpty) {
          try {
            final audioFile = File(song.filePath);
            if (await audioFile.exists()) {
              totalBytes += await audioFile.length();
            }
          } catch (_) {}
        }

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
      return context.mounted ? AppLocalizations.of(context)!.settingsCalcError : 'Error calculando';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickLibraryFolder(BuildContext context) async {
    final storageService = StorageService();
    try {
      final rootUri = await storageService.pickLibraryRoot();
      if (!context.mounted) return;
      if (rootUri == null) return; // user cancelled the picker
      // Notify MusicProvider immediately so Bandeja (kept alive by the
      // bottom nav's IndexedStack) reflects the pick without the user
      // having to navigate away and back.
      context.read<MusicProvider>().setLibraryRootUri(rootUri);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderReadySnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderPickError(e.toString())),
          backgroundColor: Colors.red.withValues(alpha: 0.8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final musicProvider = Provider.of<MusicProvider>(context);
    final l10n = AppLocalizations.of(context)!;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
        children: [
          Text(
            l10n.settingsTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.settingsSectionStorage),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<String>(
              key: ValueKey(musicProvider.libraryRootUri),
              future: _calculateStorageUsage(context, musicProvider.libraryRootUri),
              builder: (context, snapshot) {
                final storage = snapshot.data ?? l10n.settingsCalculating;
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
                          l10n.settingsSpaceUsed,
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
                      l10n.settingsTotalDownloadedSongs,
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
          _SectionTitle(l10n.settingsSectionAppearance),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settingsThemeColor,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                ...AppThemePreset.values.map((preset) {
                  final selected = settings.preset == preset;
                  final isCustom = preset == AppThemePreset.custom;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => isCustom
                            ? _showCustomThemeSheet(context, settings)
                            : settings.setPreset(preset),
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
                                  settings.presetLabel(context, preset),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (isCustom)
                                Icon(
                                  Icons.tune_rounded,
                                  color: selected
                                      ? AppTheme.primaryLight
                                      : Colors.white.withValues(alpha: 0.4),
                                  size: 20,
                                )
                              else if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: AppTheme.primaryLight,
                                  size: 20,
                                ),
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
          _SectionTitle(l10n.settingsSectionLanguage),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...AppLanguage.values.map((lang) {
                  final selected = settings.language == lang;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => settings.setLanguage(lang),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.language_rounded,
                                color: selected ? AppTheme.primaryLight : Colors.white54,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  settings.languageLabel(lang),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: AppTheme.primaryLight,
                                  size: 20,
                                ),
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
          _SectionTitle(l10n.settingsSectionPlaylistOrder),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            child: musicProvider.playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l10n.settingsCreatePlaylistsHint,
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
          _SectionTitle(l10n.settingsSectionLocalLibrary),
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
                      Icons.folder_open_rounded,
                      color: AppTheme.primaryLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.settingsImportFromFolder,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsImportFolderBody,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.folder_rounded, size: 18),
                    label: Text(
                      l10n.settingsChooseFolder,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _pickLibraryFolder(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionAdvanced),
          const SizedBox(height: 10),
          const _AdvancedSettingsSection(),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionSearch),
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
                      l10n.settingsMaxResults,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.settingsMaxResultsBody,
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
                          ? () => settings.setMaxSearchResults(
                              settings.maxSearchResults - 10,
                            )
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
                          ? () => settings.setMaxSearchResults(
                              settings.maxSearchResults + 10,
                            )
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionAbout),
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
                  l10n.settingsAboutBody,
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
  final List<Map<String, dynamic>> topArtists;
  final List<Map<String, dynamic>> topSongs;

  const _StatisticsData({
    required this.totalPlays,
    required this.totalListenSeconds,
    required this.topArtists,
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
      isWeek
          ? db.getTotalListenTimeThisWeek()
          : db.getTotalListenTimeThisMonth(),
      isWeek ? db.getTopArtistsThisWeek() : db.getTopArtistsThisMonth(),
      isWeek
          ? db.getTopSongsThisWeek(limit: 10)
          : db.getTopSongsThisMonth(limit: 10),
    ]);

    return _StatisticsData(
      totalPlays: results[0] as int,
      totalListenSeconds: results[1] as int,
      topArtists: results[2] as List<Map<String, dynamic>>,
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
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l10n.statsSectionTitle),
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
                    l10n.statsYourActivity,
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
                  if (data == null ||
                      (data.totalPlays == 0 && data.topSongs.isEmpty)) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.statsEmptyHint,
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
                              label: l10n.statsPlaysLabel,
                              value: '${data.totalPlays}',
                              icon: Icons.play_circle_outline_rounded,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _StatMiniCard(
                              label: l10n.statsListenTimeLabel,
                              value: _formatListenTime(data.totalListenSeconds),
                              icon: Icons.schedule_rounded,
                            ),
                          ),
                        ],
                      ),
                      if (data.topArtists.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          l10n.statsTopArtists,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...List.generate(data.topArtists.length, (index) {
                          final artist = data.topArtists[index];
                          return _TopArtistRow(
                            rank: index + 1,
                            name: artist['artist'] as String? ?? l10n.statsUnknownArtist,
                            playCount: artist['playCount'] as int? ?? 0,
                          );
                        }),
                      ],
                      if (data.topSongs.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          l10n.statsTopSongs,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...List.generate(
                          _isExpanded
                              ? data.topSongs.length
                              : (data.topSongs.length > 5
                                    ? 5
                                    : data.topSongs.length),
                          (index) {
                            final song = data.topSongs[index];
                            return _TopSongRow(
                              rank: index + 1,
                              title: song['title'] as String? ?? l10n.statsUntitledSong,
                              artist:
                                  song['artist'] as String? ?? l10n.statsUnknownArtist,
                              artPath: song['artPath'] as String? ?? '',
                              playCount: song['playCount'] as int? ?? 0,
                            );
                          },
                        ),
                        if (data.topSongs.length > 5)
                          Center(
                            child: IconButton(
                              icon: Icon(
                                _isExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
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

  const _PeriodToggle({required this.isWeek, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PeriodChip(
            label: l10n.statsWeek,
            selected: isWeek,
            onTap: () => onChanged(true),
          ),
          _PeriodChip(
            label: l10n.statsMonth,
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
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.5),
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

class _TopArtistRow extends StatelessWidget {
  final int rank;
  final String name;
  final int playCount;

  const _TopArtistRow({
    required this.rank,
    required this.name,
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.person_rounded,
              color: Colors.white.withValues(alpha: 0.7),
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
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
          ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildArt()),
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

/// Configuración del microservidor de descargas (`server/` en este repo).
///
/// "Probar conexión" distingue los tres fallos que el usuario puede arreglar
/// —sin configurar, inalcanzable, clave inválida— en vez de un genérico
/// "error", porque cada uno se corrige en un sitio distinto.
/// Colapsado por defecto: el usuario promedio ya está en el servidor
/// oficial sin haber tocado nada acá, así que esta pantalla nunca necesita
/// abrirse para que la app funcione. Sólo existe para quien quiera apuntar
/// a su propio servidor (ver docs/arquitectura_servidor_hibrido.md, sección 4).
class _AdvancedSettingsSection extends StatelessWidget {
  const _AdvancedSettingsSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.glassCard(),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          iconColor: AppTheme.primaryLight,
          collapsedIconColor: Colors.white.withValues(alpha: 0.5),
          title: Row(
            children: [
              Icon(Icons.dns_rounded, color: AppTheme.primaryLight, size: 20),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context)!.serverSectionTitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          children: const [_DownloadServerSection()],
        ),
      ),
    );
  }
}

class _DownloadServerSection extends StatefulWidget {
  const _DownloadServerSection();

  @override
  State<_DownloadServerSection> createState() => _DownloadServerSectionState();
}

class _DownloadServerSectionState extends State<_DownloadServerSection> {
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  bool _testing = false;
  bool _obscureKey = true;
  DownloadSourceStatus? _lastStatus;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _urlController = TextEditingController(text: settings.downloadServerUrl);
    _keyController = TextEditingController(text: settings.downloadServerApiKey);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    // Se guarda primero: si el usuario sale de Ajustes mientras se prueba, lo
    // que escribió no se pierde.
    await context.read<SettingsProvider>().setDownloadServer(
      url: _urlController.text,
      apiKey: _keyController.text,
    );
    if (!mounted) return;

    setState(() {
      _testing = true;
      _lastStatus = null;
    });

    final source = YtdlpServerSource(
      baseUrl: () => _urlController.text,
      apiKey: () => _keyController.text,
    );
    try {
      final status = await source.probe();
      if (!mounted) return;
      setState(() => _lastStatus = status);
    } finally {
      // Un único finally, no un reset por cada salida: la convención existe
      // porque una ruta de salida sin probar dejaba la UI bloqueada.
      if (mounted) setState(() => _testing = false);
    }
  }

  ({Color color, IconData icon, String text})? _statusLine() {
    final status = _lastStatus;
    if (status == null) return null;
    if (!status.reachable) {
      return (
        color: Colors.redAccent,
        icon: Icons.cloud_off_rounded,
        text: status.detail,
      );
    }
    if (!status.authenticated) {
      return (
        color: Colors.orangeAccent,
        icon: Icons.key_off_rounded,
        text: status.detail,
      );
    }
    if (!status.potProviderReachable) {
      return (
        color: Colors.orangeAccent,
        icon: Icons.warning_amber_rounded,
        text: status.detail,
      );
    }
    return (
      color: Colors.greenAccent,
      icon: Icons.cloud_done_rounded,
      text: AppLocalizations.of(context)!.serverConnectedStatus(status.version ?? '?'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    final line = _statusLine();
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.serverIntroBody,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
            height: 1.4,
          ),
        ),
        if (!settings.isOfficialServer) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryLight,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: Text(
                l10n.serverRestoreOfficial,
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: () async {
                await settings.restoreOfficialServer();
                if (!mounted) return;
                setState(() {
                  _urlController.text = settings.downloadServerUrl;
                  _keyController.text = settings.downloadServerApiKey;
                  _lastStatus = null;
                });
              },
            ),
          ),
        ],
        const SizedBox(height: 14),
        TextField(
          controller: _urlController,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.serverAddressLabel,
            hintText: '192.168.1.50:8080',
            labelStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
            ),
            hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.25),
              fontSize: 13,
            ),
            border: fieldBorder,
            enabledBorder: fieldBorder,
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.primaryLight),
            ),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _keyController,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          obscureText: _obscureKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.serverApiKeyLabel,
            labelStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
            ),
            border: fieldBorder,
            enabledBorder: fieldBorder,
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.primaryLight),
            ),
            isDense: true,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureKey
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                color: Colors.white.withValues(alpha: 0.4),
                size: 18,
              ),
              onPressed: () => setState(() => _obscureKey = !_obscureKey),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.wifi_tethering_rounded, size: 18),
            label: Text(
              _testing ? l10n.serverTestingButton : l10n.serverSaveAndTestButton,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onPressed: _testing ? null : _saveAndTest,
          ),
        ),
        if (line != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(line.icon, color: line.color, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  line.text,
                  style: TextStyle(
                    color: line.color,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
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
    final colors = AppTheme.previewColors(preset);
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

// --- PERSONALIZACIÓN DE COLORES ---

const _customThemeSwatches = <Color>[
  Color(0xFFEF4444), // red
  Color(0xFFF97316), // orange
  Color(0xFFF59E0B), // amber
  Color(0xFFEAB308), // yellow
  Color(0xFF84CC16), // lime
  Color(0xFF22C55E), // green
  Color(0xFF10B981), // emerald
  Color(0xFF14B8A6), // teal
  Color(0xFF06B6D4), // cyan
  Color(0xFF0EA5E9), // sky
  Color(0xFF3B82F6), // blue
  Color(0xFF6366F1), // indigo
  Color(0xFF8B5CF6), // violet
  Color(0xFFA855F7), // purple
  Color(0xFFD946EF), // fuchsia
  Color(0xFFEC4899), // pink
  Color(0xFFF43F5E), // rose
  Color(0xFF64748B), // slate (neutro)
];

Future<void> _showCustomThemeSheet(
  BuildContext context,
  SettingsProvider settings,
) async {
  final result = await showModalBottomSheet<(Color, Color, bool)>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CustomThemeSheet(
      initialPrimary: settings.customPrimary,
      initialSecondary: settings.customSecondary,
      initialCombined: settings.customCombined,
    ),
  );
  if (result == null) return;
  await settings.setCustomColors(
    primary: result.$1,
    secondary: result.$2,
    combined: result.$3,
  );
}

class _CustomThemeSheet extends StatefulWidget {
  final Color initialPrimary;
  final Color initialSecondary;
  final bool initialCombined;

  const _CustomThemeSheet({
    required this.initialPrimary,
    required this.initialSecondary,
    required this.initialCombined,
  });

  @override
  State<_CustomThemeSheet> createState() => _CustomThemeSheetState();
}

class _CustomThemeSheetState extends State<_CustomThemeSheet> {
  late Color _primary = widget.initialPrimary;
  late Color _secondary = widget.initialSecondary;
  late bool _combined = widget.initialCombined;
  late final _primaryHexController = TextEditingController(text: _hex(_primary));
  late final _secondaryHexController = TextEditingController(text: _hex(_secondary));

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

  Color? _parseHex(String input) {
    var s = input.trim().replaceFirst('#', '');
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length != 6) return null;
    final value = int.tryParse(s, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }

  @override
  void dispose() {
    _primaryHexController.dispose();
    _secondaryHexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.themeCustomizeTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                _buildPreview(),
                const SizedBox(height: 20),
                Text(
                  l10n.themePrimaryColorLabel,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                ),
                const SizedBox(height: 10),
                _buildSwatchGrid(_primary, (c) {
                  setState(() {
                    _primary = c;
                    _primaryHexController.text = _hex(c);
                  });
                }),
                const SizedBox(height: 8),
                _buildHexField(_primaryHexController, (c) => setState(() => _primary = c)),
                const SizedBox(height: 20),
                Text(
                  l10n.themeSecondaryColorLabel,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                ),
                const SizedBox(height: 10),
                _buildSwatchGrid(_secondary, (c) {
                  setState(() {
                    _secondary = c;
                    _secondaryHexController.text = _hex(c);
                  });
                }),
                const SizedBox(height: 8),
                _buildHexField(_secondaryHexController, (c) => setState(() => _secondary = c)),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: _primary,
                  title: Text(l10n.themeCombinedToggle, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    _combined ? l10n.themeCombinedOnHint : l10n.themeCombinedOffHint,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                  ),
                  value: _combined,
                  onChanged: (v) => setState(() => _combined = v),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context, (_primary, _secondary, _combined)),
                    child: Text(l10n.commonConfirm),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      height: 56,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
      child: _combined
          ? DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [_primary, _secondary]),
              ),
            )
          : Row(
              children: [
                Expanded(child: ColoredBox(color: _primary)),
                Expanded(child: ColoredBox(color: _secondary)),
              ],
            ),
    );
  }

  Widget _buildSwatchGrid(Color selected, ValueChanged<Color> onSelect) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _customThemeSwatches.map((c) {
        final isSelected = c.toARGB32() == selected.toARGB32();
        return GestureDetector(
          onTap: () => onSelect(c),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: isSelected ? Border.all(color: Colors.white, width: 2.5) : null,
              boxShadow: isSelected
                  ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 8)]
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHexField(TextEditingController controller, ValueChanged<Color> onValid) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: const InputDecoration(isDense: true, hintText: '#RRGGBB'),
        onSubmitted: (value) {
          final c = _parseHex(value);
          if (c != null) onValid(c);
        },
      ),
    );
  }
}
