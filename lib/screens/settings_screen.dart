import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final musicProvider = Provider.of<MusicProvider>(context);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
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
