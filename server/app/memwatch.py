"""Cuánta memoria usa el contenedor, y quién.

Render reinicia la instancia al pasar el límite del plan y avisa por correo,
pero el aviso no dice qué proceso lo causó ni cuánto faltaba. Este módulo lee
lo que el kernel ya sabe — el uso y el pico del cgroup (la misma cifra que
mide la plataforma) y el RSS de cada proceso visible en /proc — y lo resume
en una línea de log tras cada extracción. Con eso, un reinicio por memoria se
diagnostica leyendo el log, no adivinando.

Sólo tiene datos en Linux; en cualquier otro sitio informa que no los tiene y
no falla. Nunca lanza: es diagnóstico, no puede tumbar una petición.
"""
import ctypes
import logging
import sys
from pathlib import Path

log = logging.getLogger(__name__)

_MB = 1024 * 1024
_PROC = Path("/proc")

# cgroup v2 primero (es lo que trae cualquier kernel/Docker reciente), v1 de
# respaldo. `memory.peak` es el máximo desde que arrancó el contenedor: es la
# cifra que hay que mirar, porque el uso instantáneo de después de una descarga
# ya no muestra el pico que la produjo.
_CGROUP_FILES = (
    ("/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.peak"),
    ("/sys/fs/cgroup/memory/memory.usage_in_bytes", "/sys/fs/cgroup/memory/memory.max_usage_in_bytes"),
)


def parse_proc_status(text: str) -> tuple[str, int] | None:
    """(nombre, RSS en bytes) de un /proc/<pid>/status; None si falta alguno."""
    name = None
    rss = None
    for line in text.splitlines():
        if line.startswith("Name:"):
            name = line.partition(":")[2].strip()
        elif line.startswith("VmRSS:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                rss = int(parts[1]) * 1024
    if not name or rss is None:
        return None
    return name, rss


def parse_cgroup_bytes(text: str) -> int | None:
    """Los archivos del cgroup traen un entero o "max"; "max" es "sin dato"."""
    value = text.strip()
    return int(value) if value.isdigit() else None


def summarize(
    processes: list[tuple[str, int]],
    container_current: int | None,
    container_peak: int | None,
) -> dict:
    """Agrupa por nombre de proceso (un `node` por token y otro por firma se
    ven como "node ×2"), ordenado de mayor a menor RSS."""
    by_name: dict[str, dict] = {}
    for name, rss in processes:
        entry = by_name.setdefault(name, {"name": name, "rssBytes": 0, "count": 0})
        entry["rssBytes"] += rss
        entry["count"] += 1
    ordered = sorted(by_name.values(), key=lambda e: e["rssBytes"], reverse=True)
    return {
        "containerBytes": container_current,
        "containerPeakBytes": container_peak,
        "processes": ordered,
    }


def _mb(value: int | None) -> str:
    return "?" if value is None else f"{value / _MB:.0f} MB"


def format_report(summary: dict) -> str:
    """Una sola línea: 'contenedor 310 MB (pico 455 MB); python3 190 MB, node 95 MB ×2'."""
    head = f"contenedor {_mb(summary['containerBytes'])} (pico {_mb(summary['containerPeakBytes'])})"
    parts = []
    for entry in summary["processes"]:
        text = f"{entry['name']} {_mb(entry['rssBytes'])}"
        if entry["count"] > 1:
            text += f" ×{entry['count']}"
        parts.append(text)
    return head + ("; " + ", ".join(parts) if parts else "")


def _read_cgroup() -> tuple[int | None, int | None]:
    for current_path, peak_path in _CGROUP_FILES:
        try:
            current = parse_cgroup_bytes(Path(current_path).read_text())
        except OSError:
            continue
        try:
            peak = parse_cgroup_bytes(Path(peak_path).read_text())
        except OSError:
            peak = None
        return current, peak
    return None, None


def _read_processes() -> list[tuple[str, int]]:
    found = []
    try:
        entries = list(_PROC.iterdir())
    except OSError:
        return found
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            parsed = parse_proc_status((entry / "status").read_text())
        except OSError:
            continue  # el proceso terminó entre el listado y la lectura
        if parsed is not None:
            found.append(parsed)
    return found


def snapshot() -> dict:
    """Resumen estructurado (para /health/detail). Sin datos fuera de Linux."""
    if not sys.platform.startswith("linux"):
        return summarize([], None, None)
    try:
        current, peak = _read_cgroup()
        return summarize(_read_processes(), current, peak)
    except Exception as e:  # noqa: BLE001 — diagnóstico, nunca tumba nada
        log.debug("memwatch: sin datos (%s)", type(e).__name__)
        return summarize([], None, None)


def describe() -> str:
    """La línea para el log."""
    return format_report(snapshot())


_libc = None


def release_freed_memory() -> None:
    """Devuelve al sistema la memoria que Python ya liberó pero glibc retiene.

    yt-dlp aloja y suelta decenas de MB por extracción (la respuesta del
    player, la lista de formatos, el JS del reproductor). CPython los libera,
    pero glibc los deja en sus arenas para reutilizarlos y el RSS no baja — y
    el RSS es lo que cuenta contra el límite del contenedor. `malloc_trim`
    recorta esas arenas; con MALLOC_ARENA_MAX bajo (ver Dockerfile) es lo que
    hace que la memoria del proceso vuelva al nivel de reposo entre descargas.
    """
    global _libc
    if not sys.platform.startswith("linux"):
        return
    try:
        if _libc is None:
            _libc = ctypes.CDLL("libc.so.6")
        _libc.malloc_trim(0)
    except Exception as e:  # noqa: BLE001
        log.debug("memwatch: malloc_trim no disponible (%s)", type(e).__name__)
