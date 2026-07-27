import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static Future<File> _getLogFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/download_errors.log');
  }

  static Future<void> logError(String message, [dynamic error, StackTrace? stack]) async {
    try {
      final file = await _getLogFile();
      final timestamp = DateTime.now().toIso8601String();
      final logMessage = '[$timestamp] $message\nError: $error\n${stack != null ? 'Stack:\n$stack\n' : ''}\n';
      await file.writeAsString(logMessage, mode: FileMode.append);
      print(logMessage);
    } catch (e) {
      print('Failed to write log: $e');
    }
  }

  static Future<String> readLogs() async {
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {}
    return 'No hay registros de errores disponibles.';
  }

  static Future<void> clearLogs() async {
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
