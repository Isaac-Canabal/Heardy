import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Captura un `RepaintBoundary` a PNG. Guarda contra `debugNeedsPaint`: pedir
/// `toImage()` sobre un boundary que todavía no terminó de pintar lanza o
/// captura contenido viejo — un reintento acotado resuelve el caso normal
/// (la vista previa recién se montó, o la animación de entrada de la hoja
/// modal todavía está corriendo) sin un `Future.delayed` fijo que adivine mal
/// según la velocidad del dispositivo.
///
/// **10 × 50ms (hasta 500ms), no 3 × 32ms**: el presupuesto original no
/// alcanzaba en un dispositivo real — la transición de entrada del
/// `showModalBottomSheet` (~250ms) por sí sola ya superaba las 3 pasadas
/// enteras, así que el botón de compartir devolvía `null` en silencio y
/// parecía "no hacer nada".
Future<Uint8List?> renderBoundaryPng(GlobalKey key, {double pixelRatio = 3}) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary || renderObject.debugNeedsPaint) {
      await Future.delayed(const Duration(milliseconds: 50));
      continue;
    }
    // La tarjeta crece con su contenido, así que su alto no está acotado de
    // antemano: con un top largo, ×3 daría un bitmap de varios miles de
    // píxeles de alto y podría quedarse sin memoria en un equipo modesto.
    // Se baja el factor sólo en ese caso, en vez de recortar el contenido.
    var effectiveRatio = pixelRatio;
    final height = renderObject.size.height;
    if (height * effectiveRatio > _maxPixelHeight) {
      effectiveRatio = (_maxPixelHeight / height).clamp(1.0, pixelRatio);
    }

    final image = await renderObject.toImage(pixelRatio: effectiveRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
  return null;
}

/// Alto máximo del PNG exportado, en píxeles reales.
const double _maxPixelHeight = 4000;

/// Espera a que termine el frame actual — junto con `precacheImage` de las
/// carátulas, es lo que asegura que la captura no se adelante al decodificado
/// asíncrono de las imágenes que la tarjeta muestra.
Future<void> waitForEndOfFrame() => SchedulerBinding.instance.endOfFrame;

/// Escribe el PNG en el directorio temporal y delega en `share_plus`. El
/// archivo NO se borra al instante (la app receptora puede leerlo con calma);
/// se barren los de más de un día en el siguiente llamado.
Future<void> shareStatsImage(Uint8List pngBytes, {String filenamePrefix = 'heardy_stats'}) async {
  final dir = await getTemporaryDirectory();
  await _sweepOldShareImages(dir, prefix: filenamePrefix);

  final path = '${dir.path}/${filenamePrefix}_${DateTime.now().millisecondsSinceEpoch}.png';
  final file = File(path);
  await file.writeAsBytes(pngBytes, flush: true);

  await SharePlus.instance.share(
    ShareParams(files: [XFile(path, mimeType: 'image/png')]),
  );
}

Future<void> _sweepOldShareImages(Directory dir, {required String prefix}) async {
  try {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(prefix)) continue;
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        await entity.delete();
      }
    }
  } catch (_) {
    // Barrido oportunista: un fallo acá no debe impedir compartir la imagen actual.
  }
}
