import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Rich download progress panel with large percentage display.
class DownloadProgressCard extends StatelessWidget {
  final double progress;
  final String statusMessage;
  final String currentTitle;
  final Duration elapsed;
  final VoidCallback onCancel;

  const DownloadProgressCard({
    super.key,
    required this.progress,
    required this.statusMessage,
    required this.currentTitle,
    required this.elapsed,
    required this.onCancel,
  });

  int get _percent => (progress.clamp(0.0, 1.0) * 100).round();

  bool get _hasStarted => progress > 0;

  String get _elapsedLabel {
    final m = elapsed.inMinutes;
    final s = elapsed.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get _phaseLabel {
    if (_hasStarted) return 'En progreso';
    final msg = statusMessage.toLowerCase();
    if (msg.contains('esperando')) return 'Esperando a YouTube…';
    if (msg.contains('reintentando')) return 'Reintentando…';
    if (msg.contains('preparando')) return 'Preparando enlace…';
    if (msg.contains('obteniendo')) return 'Obteniendo datos…';
    if (msg.contains('iniciando')) return 'Iniciando…';
    return 'Conectando…';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.glassCard(highlighted: true),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProgressRing(percent: _percent, active: _hasStarted),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.cloud_download_rounded,
                          color: AppTheme.accent.withValues(alpha: 0.9),
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Descargando',
                          style: TextStyle(
                            color: AppTheme.primaryLight,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          icon: Icon(
                            Icons.close_rounded,
                            color: Colors.redAccent.shade100,
                            size: 22,
                          ),
                          onPressed: onCancel,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      statusMessage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        height: 1.3,
                      ),
                    ),
                    if (currentTitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        currentTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$_percent',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: -1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 2),
                child: Text(
                  '%',
                  style: TextStyle(
                    color: AppTheme.primaryLight.withValues(alpha: 0.9),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _elapsedLabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _phaseLabel,
                    style: TextStyle(
                      color: _hasStarted ? AppTheme.accent : Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _GradientProgressBar(value: progress),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '0%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                ),
              ),
              Text(
                '100%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  final int percent;
  final bool active;

  const _ProgressRing({required this.percent, required this.active});

  @override
  Widget build(BuildContext context) {
    final value = active ? (percent / 100).clamp(0.01, 1.0) : null;

    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
          ),
          Icon(
            active ? Icons.music_note_rounded : Icons.wifi_tethering_rounded,
            color: active ? AppTheme.primaryLight : Colors.white38,
            size: 22,
          ),
        ],
      ),
    );
  }
}

class _GradientProgressBar extends StatelessWidget {
  final double value;

  const _GradientProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.white.withValues(alpha: 0.08)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: clamped > 0 ? clamped : 0.02,
              child: Container(
                decoration: BoxDecoration(
                  gradient: AppTheme.progressGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.38),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
