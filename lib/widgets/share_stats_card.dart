import 'package:flutter/material.dart';

import '../models/statistics_data.dart';
import '../theme/app_theme.dart';
import '../widgets/statistics_view.dart';

/// Tamaño lógico FIJO × `pixelRatio: 3` (ver `share_image_service.dart`) da un
/// PNG de 1080×1920 de forma determinista tenga la cuenta 2 o 10 canciones —
/// el espaciador de abajo es lo que evita que una lista corta deje un hueco
/// feo en vez de estirarse.
class ShareStatsCard extends StatelessWidget {
  final String username;
  final StatisticsData data;
  final bool isWeek;

  const ShareStatsCard({super.key, required this.username, required this.data, required this.isWeek});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: 640,
      child: Container(
        // Fondo OPACO a propósito: `AppTheme.glassCard()` es translúcido, así
        // que un `RepaintBoundary` a su alrededor se pintaría sobre
        // transparencia si esta tarjeta no pusiera su propio fondo.
        decoration: AppTheme.gradientScaffold(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@$username',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: StatisticsView(
                  data: data,
                  isWeek: isWeek,
                  decorated: false,
                  onPeriodChanged: null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'Heardy',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
