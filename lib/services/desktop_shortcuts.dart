import 'package:flutter/services.dart';

/// Qué hacer con una tecla física del teclado de escritorio, si algo — ver
/// W3 del plan de escritorio (`heardy-escritorio-windows.md`). Extraída pura
/// para poder probarla sin levantar un árbol de widgets.
enum DesktopPlaybackShortcut { playPause, seekBack, seekForward, none }

DesktopPlaybackShortcut desktopShortcutFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return DesktopPlaybackShortcut.playPause;
  if (key == LogicalKeyboardKey.arrowLeft) return DesktopPlaybackShortcut.seekBack;
  if (key == LogicalKeyboardKey.arrowRight) return DesktopPlaybackShortcut.seekForward;
  return DesktopPlaybackShortcut.none;
}
