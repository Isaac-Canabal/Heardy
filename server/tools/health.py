"""Comprueba el servidor de descargas y explica qué hacer si algo falla.

Uso:
    python tools/health.py                 # solo /health
    python tools/health.py --url URL       # además resuelve esa URL de YouTube
    python tools/health.py --audio         # y descarga el audio a un temporal

`--url` es lo que de verdad prueba la cadena entera contra YouTube: /health
puede decir que todo está bien y las descargas fallar igual si el plugin y el
servidor del proveedor de PO tokens no son de la misma versión.
"""
import argparse
import json
import sys
import tempfile
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config  # noqa: E402


def base_url() -> str:
    host = "127.0.0.1" if config.HOST in ("0.0.0.0", "") else config.HOST
    return f"http://{host}:{config.PORT}"


def check_health(client: httpx.Client) -> bool:
    try:
        response = client.get(f"{base_url()}/health", timeout=10)
    except httpx.ConnectError:
        print(f"[FALLO] No hay nadie escuchando en {base_url()}")
        print("        Arrancá la API con run.bat (o run-api.bat).")
        return False
    except httpx.HTTPError as e:
        print(f"[FALLO] Error de red hablando con {base_url()}: {e}")
        return False

    if response.status_code != 200:
        print(f"[FALLO] /health respondió {response.status_code}")
        print(response.text[:500])
        return False

    data = response.json()
    print(json.dumps(data, indent=2, ensure_ascii=False))
    print()

    pot = data.get("potProvider", {})
    ok = True

    print(f"[OK]    API viva en {base_url()}")
    print(f"[OK]    yt-dlp {data.get('ytdlpVersion')}")

    if pot.get("reachable"):
        print(f"[OK]    Proveedor de PO tokens responde ({pot.get('url')})")
    else:
        ok = False
        print(f"[FALLO] El proveedor de PO tokens NO responde ({pot.get('url')})")
        print(f"        Detalle: {pot.get('detail')}")
        print("        Arrancalo con run-pot.bat y dejá esa ventana abierta.")
        print("        Sin él, la mayoría de descargas devolverán 403.")

    if data.get("authRequired"):
        print("[OK]    Autenticación activada")
    else:
        print("[AVISO] Autenticación DESACTIVADA (HEARDY_ALLOW_NO_AUTH=1).")
        print("        Vale para probar en local; no lo dejes así si abrís el puerto.")

    return ok


def check_resolve(client: httpx.Client, url: str) -> dict | None:
    """Resuelve [url] UNA vez y devuelve la pista, o None si falló.

    Una sola petición a propósito: cada llamada gasta presupuesto de IP frente
    a YouTube, que es el recurso escaso de todo este montaje.
    """
    print(f"\n--- Resolviendo {url}")
    try:
        response = client.post(
            f"{base_url()}/resolve",
            json={"url": url},
            headers={"X-Api-Key": config.API_KEY},
            timeout=120,
        )
    except httpx.HTTPError as e:
        print(f"[FALLO] {e}")
        return None

    if response.status_code == 401:
        print("[FALLO] 401: la clave de API no coincide.")
        print("        Comprobá HEARDY_API_KEY en server/.env y reiniciá la API.")
        return None
    if response.status_code != 200:
        print(f"[FALLO] {response.status_code}: {response.text[:600]}")
        if "bot" in response.text.lower() or "403" in response.text:
            print("\n        Huele a bloqueo de YouTube. Comprobá que el proveedor de")
            print("        PO tokens esté vivo y que su versión coincida con la del")
            print("        plugin (setup.bat lo fija por etiqueta).")
        return None

    track = response.json()
    print(json.dumps(track, indent=2, ensure_ascii=False))
    print(f"\n[OK]    Resuelto: {track.get('artist')} - {track.get('title')} "
          f"({track.get('durationSeconds')}s)")
    return track


def check_audio(client: httpx.Client, track_id: str) -> bool:
    print(f"\n--- Descargando audio de {track_id} (puede tardar)")
    dest = Path(tempfile.gettempdir()) / f"heardy_health_{track_id}.m4a"
    try:
        with client.stream(
            "GET",
            f"{base_url()}/audio/{track_id}",
            headers={"X-Api-Key": config.API_KEY},
            timeout=300,
        ) as response:
            if response.status_code != 200:
                body = response.read().decode("utf-8", "replace")
                print(f"[FALLO] {response.status_code}: {body[:600]}")
                if response.status_code == 415:
                    print("        415 = ese vídeo no tiene pista AAC/M4A. Probá con otro.")
                return False
            with open(dest, "wb") as handle:
                for chunk in response.iter_bytes():
                    handle.write(chunk)
    except httpx.HTTPError as e:
        print(f"[FALLO] {e}")
        return False

    size = dest.stat().st_size
    print(f"[OK]    {size:,} bytes en {dest}")

    # Comprobación barata de que es realmente un MP4/M4A: la caja `ftyp` va
    # en los bytes 4-8 de todo contenedor MP4.
    with open(dest, "rb") as handle:
        header = handle.read(12)
    if header[4:8] == b"ftyp":
        print("[OK]    Es un contenedor MP4/M4A válido (caja ftyp presente)")
    else:
        print(f"[FALLO] No parece un MP4: cabecera {header[:12]!r}")
        return False

    print("\n        Para confirmar que el audio es AAC sin recodificar:")
    print(f"            ffprobe \"{dest}\"")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Diagnóstico del servidor de descargas")
    parser.add_argument("--url", help="URL de YouTube para probar /resolve")
    parser.add_argument("--audio", action="store_true",
                        help="Además descargar el audio (requiere --url)")
    args = parser.parse_args()

    with httpx.Client(follow_redirects=False) as client:
        healthy = check_health(client)
        if not healthy and not args.url:
            sys.exit(1)

        if args.url:
            if not config.API_KEY and not config.ALLOW_NO_AUTH:
                print("\n[FALLO] No hay HEARDY_API_KEY en server/.env. Ejecutá make-key.bat.")
                sys.exit(1)
            track = check_resolve(client, args.url)
            if track is None:
                sys.exit(1)
            if args.audio and not check_audio(client, track["id"]):
                sys.exit(1)

    print("\nTodo correcto.")


if __name__ == "__main__":
    main()
