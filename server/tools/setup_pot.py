"""Instala y compila el proveedor de PO Tokens (bgutil) para ejecución nativa.

El proveedor tiene dos mitades y **sus versiones deben coincidir**:
  - el plugin de yt-dlp, que se instala por pip (está en requirements.txt);
  - el servidor HTTP, que es un proyecto Node y hay que compilar.

Este script lee la versión del plugin ya instalado y clona el servidor en esa
misma etiqueta, en vez de coger la rama por defecto. Un desajuste entre las
dos mitades es el fallo silencioso más probable de todo el montaje: el
servidor arranca, /health dice que el proveedor responde, y las descargas
fallan igual con 403.

Uso:  python tools/setup_pot.py
"""
import importlib.metadata
import shutil
import subprocess
import sys
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
PROVIDER_DIR = SERVER_ROOT / ".pot-provider"
REPO_URL = "https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git"
PLUGIN_PACKAGE = "bgutil-ytdlp-pot-provider"


def fail(message: str) -> None:
    print(f"\n[ERROR] {message}\n", file=sys.stderr)
    sys.exit(1)


def run(command, cwd: Path, shell: bool = False) -> subprocess.CompletedProcess:
    printable = command if isinstance(command, str) else " ".join(command)
    print(f"  > {printable}")
    return subprocess.run(command, cwd=cwd, shell=shell)


def plugin_version() -> str | None:
    try:
        return importlib.metadata.version(PLUGIN_PACKAGE)
    except importlib.metadata.PackageNotFoundError:
        return None


def main() -> None:
    if shutil.which("git") is None:
        fail("git no está en el PATH. Instalalo desde https://git-scm.com/download/win")
    if shutil.which("node") is None:
        fail(
            "Node.js no está en el PATH. El proveedor de PO tokens es una aplicación "
            "Node. Instalalo desde https://nodejs.org (LTS) y volvé a abrir la terminal."
        )

    version = plugin_version()
    if version is None:
        fail(
            f"El plugin '{PLUGIN_PACKAGE}' no está instalado. Ejecutá setup.bat, que "
            "instala requirements.txt antes de llamar a este script."
        )
    print(f"Plugin de yt-dlp instalado: {PLUGIN_PACKAGE} {version}")

    # En Windows npm es un .cmd, así que hace falta shell=True para invocarlo.
    use_shell = sys.platform == "win32"

    if PROVIDER_DIR.exists():
        print(f"\nActualizando el proveedor ya clonado en {PROVIDER_DIR}")
        run(["git", "fetch", "--tags", "--force"], cwd=PROVIDER_DIR)
        checkout = run(["git", "checkout", "--force", version], cwd=PROVIDER_DIR)
    else:
        print(f"\nClonando el proveedor en {PROVIDER_DIR} (etiqueta {version})")
        checkout = run(
            ["git", "clone", "--single-branch", "--branch", version, REPO_URL, str(PROVIDER_DIR)],
            cwd=SERVER_ROOT,
        )

    if checkout.returncode != 0:
        print(
            f"\n[AVISO] No existe la etiqueta '{version}' en el repositorio del proveedor.\n"
            "        Se usará la rama por defecto, pero comprobá que el plugin y el\n"
            "        servidor sean compatibles: un desajuste da 403 en las descargas\n"
            "        aunque /health diga que todo está bien."
        )
        if PROVIDER_DIR.exists():
            run(["git", "checkout", "--force", "master"], cwd=PROVIDER_DIR)
        else:
            if run(["git", "clone", REPO_URL, str(PROVIDER_DIR)], cwd=SERVER_ROOT).returncode != 0:
                fail("No se pudo clonar el repositorio del proveedor.")

    node_dir = PROVIDER_DIR / "server"
    if not node_dir.is_dir():
        fail(f"No se encontró {node_dir}: la estructura del repositorio cambió.")

    print("\nInstalando dependencias de Node (puede tardar un par de minutos)")
    if run("npm ci", cwd=node_dir, shell=use_shell).returncode != 0:
        # `npm ci` exige un package-lock.json coherente; `npm install` es más
        # tolerante y sirve igual para uso local.
        print("  npm ci falló, reintentando con npm install")
        if run("npm install", cwd=node_dir, shell=use_shell).returncode != 0:
            fail("No se pudieron instalar las dependencias de Node.")

    print("\nCompilando el proveedor (TypeScript -> build/)")
    if run("npx tsc", cwd=node_dir, shell=use_shell).returncode != 0:
        fail("La compilación con tsc falló.")

    built = node_dir / "build" / "main.js"
    if not built.is_file():
        fail(f"La compilación terminó pero no existe {built}.")

    print(f"\n[OK] Proveedor de PO tokens listo en {built}")
    print("     Arrancalo con run-pot.bat (escucha en http://127.0.0.1:4416)")


if __name__ == "__main__":
    main()
