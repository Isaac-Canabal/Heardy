"""El script mode del proveedor de PO tokens, ajustado a una CPU de 0,1 vCPU.

El plugin trae plazos de 15 s y 20 s como atributos de clase. Con ~0,1 vCPU
no alcanzan (fallo real de producción: `TimeoutExpired` sobre vídeos sanos),
y la imagen Docker vuelve al script mode por memoria, así que hace falta que
esos plazos se ajusten al arrancar — y que el ajuste no rompa nada si el
plugin no está o cambió por dentro.

Las clases se buscan en el registro de yt-dlp, igual que hace el código, y no
importando el módulo del plugin: importarlo a mano hace que yt-dlp lo registre
dos veces al cargar plugins (visto en vivo).
"""
import shutil

import pytest

from app import ytdlp_client

registry = pytest.importorskip("yt_dlp.extractor.youtube.pot._registry")


def _script_providers():
    from yt_dlp.plugins import load_all_plugins

    load_all_plugins()
    return [cls for key, cls in registry._pot_providers.value.items() if key.startswith("BgUtilScript")]


@pytest.fixture
def providers():
    found = _script_providers()
    if not found:
        pytest.skip("el plugin bgutil no está instalado en este entorno")
    originals = {
        cls: (cls.__dict__.get("_GETPOT_TIMEOUT"), cls.__dict__.get("_GET_SCRIPT_VSN_TIMEOUT"), cls.__dict__.get("_jsrt_path_impl"))
        for cls in found
    }
    yield found
    # Se restaura exactamente lo que había en CADA clase: si el atributo venía
    # heredado, se borra el que puso el ajuste en vez de fijarlo en la subclase.
    for cls, (getpot, vsn, jsrt) in originals.items():
        for name, value in (("_GETPOT_TIMEOUT", getpot), ("_GET_SCRIPT_VSN_TIMEOUT", vsn), ("_jsrt_path_impl", jsrt)):
            if value is not None:
                setattr(cls, name, value)
            elif name in cls.__dict__:
                delattr(cls, name)


def test_sin_script_home_no_toca_el_plugin(providers):
    before = [cls._GET_SCRIPT_VSN_TIMEOUT for cls in providers]
    assert ytdlp_client.tune_script_mode_for_slow_cpu("", 120) is False
    assert [cls._GET_SCRIPT_VSN_TIMEOUT for cls in providers] == before


def test_con_script_home_sube_los_dos_plazos_en_cada_proveedor(providers):
    assert ytdlp_client.tune_script_mode_for_slow_cpu("/opt/bgutil-server", 120) is True
    for cls in providers:
        assert cls._GETPOT_TIMEOUT == 120.0
        assert cls._GET_SCRIPT_VSN_TIMEOUT == 120.0


def test_la_ruta_del_runtime_se_toma_del_path_sin_comprobar_version(providers):
    ytdlp_client.tune_script_mode_for_slow_cpu("/opt/bgutil-server", 120)

    class FakeProvider:
        _JSRT_EXEC = "python"  # algo que seguro está en el PATH del test

    for cls in providers:
        assert cls._jsrt_path_impl(FakeProvider()) == shutil.which("python")


def test_si_el_runtime_no_esta_en_el_path_cae_a_la_comprobacion_original(providers):
    # Centinela ANTES de ajustar, para ver que el ajuste delega en lo que
    # había y no inventa una ruta.
    for cls in providers:
        cls._jsrt_path_impl = lambda self: "comprobacion-original"
    ytdlp_client.tune_script_mode_for_slow_cpu("/opt/bgutil-server", 120)

    class FakeProvider:
        _JSRT_EXEC = "un-runtime-que-no-existe-en-ninguna-maquina"

    for cls in providers:
        assert cls._jsrt_path_impl(FakeProvider()) == "comprobacion-original"
