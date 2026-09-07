"""Un fallo del ENTORNO del servidor no es un fallo del vídeo.

El caso real: el proveedor de PO tokens en "script mode" lanza un proceso Node
por token y antes comprueba que responde (`node generate_once.js --version`),
con un plazo de 15 s que el plugin fija por su cuenta. Con ~0,1 vCPU arrancar
Node no entra en ese plazo. `subprocess.TimeoutExpired` no es una excepción de
yt-dlp, así que subía sin traducir hasta FastAPI: 500 opaco, sobre un vídeo
perfectamente sano, y sin nada en el mensaje que dijera que el problema era
del servidor.
"""
import subprocess

from app import ytdlp_client


def test_timeout_de_subproceso_es_temporal_no_definitivo():
    e = subprocess.TimeoutExpired(cmd=["node", "generate_once.js", "--version"], timeout=15.0)
    error = ytdlp_client.ExtractionError(ytdlp_client._environment_message(e))
    # ExtractionError -> 502 -> reintentable. Nunca PermanentlyUnavailableError
    # (404, que descartaría la canción) ni NoAudioTrackError (415, idem).
    assert isinstance(error, ytdlp_client.ExtractionError)
    assert not isinstance(error, ytdlp_client.PermanentlyUnavailableError)


def test_el_mensaje_nombra_la_causa_probable():
    e = subprocess.TimeoutExpired(cmd=["node"], timeout=15.0)
    msg = ytdlp_client._environment_message(e)
    assert "PO tokens" in msg
    assert "CPU" in msg


def test_otros_fallos_de_entorno_dicen_el_tipo_sin_volcar_el_texto():
    # El tipo basta para diagnosticar y no arrastra rutas ni valores internos
    # al mensaje que ve el cliente.
    msg = ytdlp_client._environment_message(OSError("algo del sistema de archivos"))
    assert "OSError" in msg
    assert "algo del sistema de archivos" not in msg


def test_los_errores_de_entorno_estan_en_la_tupla_que_se_captura():
    assert subprocess.TimeoutExpired in ytdlp_client._ENVIRONMENT_ERRORS
    assert OSError in ytdlp_client._ENVIRONMENT_ERRORS
