"""Tests de app.memwatch: las funciones puras de parseo y resumen.

La lectura real de /proc y del cgroup sólo existe en Linux; acá se prueba lo
que se puede probar en cualquier sitio — que el texto que trae el kernel se
interpreta bien y que el resumen agrupa y ordena como el log necesita.
"""
from app import memwatch

STATUS_NODE = """Name:\tnode
Umask:\t0022
State:\tS (sleeping)
Pid:\t42
VmPeak:\t  1104812 kB
VmSize:\t  1038720 kB
VmRSS:\t   153600 kB
Threads:\t11
"""


def test_parse_proc_status_devuelve_nombre_y_rss_en_bytes():
    assert memwatch.parse_proc_status(STATUS_NODE) == ("node", 153600 * 1024)


def test_parse_proc_status_sin_vmrss_es_none():
    # Un hilo de kernel (kthreadd, etc.) no tiene VmRSS: no es un proceso que
    # cuente contra el límite y no debe aparecer.
    assert memwatch.parse_proc_status("Name:\tkthreadd\nPid:\t2\n") is None


def test_parse_proc_status_sin_nombre_es_none():
    assert memwatch.parse_proc_status("VmRSS:\t100 kB\n") is None


def test_parse_cgroup_bytes_entero_y_max():
    assert memwatch.parse_cgroup_bytes("325058560\n") == 325058560
    # cgroup v2 devuelve "max" cuando no hay límite ni dato.
    assert memwatch.parse_cgroup_bytes("max\n") is None


def test_summarize_agrupa_por_nombre_y_ordena_por_tamano():
    mb = 1024 * 1024
    summary = memwatch.summarize(
        [("python3", 190 * mb), ("node", 60 * mb), ("ffmpeg", 30 * mb), ("node", 40 * mb)],
        container_current=330 * mb,
        container_peak=455 * mb,
    )
    assert summary["containerBytes"] == 330 * mb
    assert summary["containerPeakBytes"] == 455 * mb
    assert [(p["name"], p["rssBytes"] // mb, p["count"]) for p in summary["processes"]] == [
        ("python3", 190, 1),
        ("node", 100, 2),
        ("ffmpeg", 30, 1),
    ]


def test_format_report_una_linea_con_pico_y_multiplicidad():
    mb = 1024 * 1024
    summary = memwatch.summarize(
        [("python3", 190 * mb), ("node", 60 * mb), ("node", 40 * mb)],
        container_current=330 * mb,
        container_peak=455 * mb,
    )
    assert memwatch.format_report(summary) == "contenedor 330 MB (pico 455 MB); python3 190 MB, node 100 MB ×2"


def test_format_report_sin_datos_no_falla():
    summary = memwatch.summarize([], None, None)
    assert memwatch.format_report(summary) == "contenedor ? (pico ?)"


def test_snapshot_y_release_nunca_lanzan_fuera_de_linux():
    # En Windows/macOS devuelven "sin datos" en vez de reventar: es diagnóstico
    # y corre dentro del finally de cada extracción.
    snapshot = memwatch.snapshot()
    assert "processes" in snapshot
    memwatch.release_freed_memory()
