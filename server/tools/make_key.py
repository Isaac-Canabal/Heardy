"""Genera HEARDY_API_KEY y la escribe en server/.env.

Windows no trae openssl, que es lo que suele documentarse para esto, así que
se usa `secrets` de la librería estándar. 32 bytes en hexadecimal es el mismo
tamaño que daría `openssl rand -hex 32`.

Uso:  python tools/make_key.py
"""
import secrets
import sys
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = SERVER_ROOT / ".env"
EXAMPLE_PATH = SERVER_ROOT / ".env.example"
KEY_NAME = "HEARDY_API_KEY"


def main() -> None:
    if not ENV_PATH.exists():
        if not EXAMPLE_PATH.exists():
            print(f"[ERROR] No existe {EXAMPLE_PATH}", file=sys.stderr)
            sys.exit(1)
        ENV_PATH.write_text(EXAMPLE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"Creado {ENV_PATH} a partir de .env.example")

    lines = ENV_PATH.read_text(encoding="utf-8").splitlines()
    existing = next(
        (ln.split("=", 1)[1].strip() for ln in lines if ln.startswith(f"{KEY_NAME}=")),
        "",
    )
    if existing:
        print(f"{KEY_NAME} ya tiene valor en {ENV_PATH}; no se toca.")
        print("Si querés rotarla, borrá esa línea y volvé a ejecutar esto.")
        print(f"\nClave actual: {existing}")
        return

    key = secrets.token_hex(32)
    replaced = False
    for i, line in enumerate(lines):
        if line.startswith(f"{KEY_NAME}="):
            lines[i] = f"{KEY_NAME}={key}"
            replaced = True
            break
    if not replaced:
        lines.append(f"{KEY_NAME}={key}")

    ENV_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Clave escrita en {ENV_PATH}\n")
    print(f"  {key}\n")
    print("Pegá exactamente ese valor en Ajustes > Servidor de descargas de la app.")


if __name__ == "__main__":
    main()
