/// Carga de estadísticas locales, fuera de la pantalla que las pinta.
///
/// Funciones de nivel superior y no una clase: no hay estado que guardar, y
/// así se prueban directamente contra una base `sqflite_common_ffi` sembrada,
/// sin renderizar nada — el mismo precedente que `missingPlaylistEntries()`.
library;

import '../models/statistics_data.dart';
import 'database_helper.dart';

/// Las cuatro consultas del periodo, en paralelo.
///
/// **Ojo con las definiciones de periodo, que son incoherentes entre sí y lo
/// son a propósito** (ver `DatabaseHelper`): "semana" es la semana natural
/// desde el lunes en hora local, y "mes" es una ventana deslizante de 30 días
/// sin huso horario. Cualquier arreglo tiene que hacerse a la vez aquí y en el
/// servidor, o las estadísticas propias y las que ve un amigo dejarían de
/// coincidir y se leería como un fallo.
Future<StatisticsData> loadLocalStatistics({
  required bool isWeek,
  DatabaseHelper? db,
}) async {
  final helper = db ?? DatabaseHelper.instance;
  final results = await Future.wait([
    isWeek ? helper.getTotalPlaysThisWeek() : helper.getTotalPlaysThisMonth(),
    isWeek ? helper.getTotalListenTimeThisWeek() : helper.getTotalListenTimeThisMonth(),
    isWeek ? helper.getTopArtistsThisWeek() : helper.getTopArtistsThisMonth(),
    isWeek ? helper.getTopSongsThisWeek(limit: 10) : helper.getTopSongsThisMonth(limit: 10),
  ]);

  return StatisticsData.fromRows(
    totalPlays: results[0] as int,
    totalListenSeconds: results[1] as int,
    topArtists: results[2] as List<Map<String, dynamic>>,
    topSongs: results[3] as List<Map<String, dynamic>>,
  );
}

/// `45 s` / `12m` / `3h 5m`. Movida tal cual desde `settings_screen.dart`.
String formatListenTime(int totalSeconds) {
  if (totalSeconds < 60) return '$totalSeconds s';
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
