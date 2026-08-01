@echo off
REM Instalacion unica del servidor de descargas de Heardy, sin Docker.
REM Crea el entorno virtual, instala las dependencias de Python y compila el
REM proveedor de PO tokens (que es una aplicacion Node).
REM
REM Requisitos previos: Python 3.10+ y Node.js LTS en el PATH. Ver README.md.

setlocal
cd /d "%~dp0"

echo === 1/4  Comprobando Python =========================================
py --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] No se encontro el lanzador "py".
    echo         Instala Python 3.10+ desde https://www.python.org/downloads/
    echo         marcando "Add python.exe to PATH" durante la instalacion.
    exit /b 1
)
py --version

echo.
echo === 2/4  Creando el entorno virtual (.venv) =========================
if exist ".venv\Scripts\python.exe" (
    echo Ya existe, se reutiliza.
) else (
    py -m venv .venv
    if errorlevel 1 (
        echo [ERROR] No se pudo crear el entorno virtual.
        exit /b 1
    )
)

echo.
echo === 3/4  Instalando dependencias de Python ==========================
call ".venv\Scripts\python.exe" -m pip install --upgrade pip
call ".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
    echo [ERROR] Fallo la instalacion de dependencias.
    exit /b 1
)

echo.
echo === 4/4  Preparando el proveedor de PO tokens =======================
call ".venv\Scripts\python.exe" tools\setup_pot.py
if errorlevel 1 (
    echo [ERROR] Fallo la preparacion del proveedor de PO tokens.
    exit /b 1
)

echo.
if not exist ".env" (
    echo === Creando .env a partir de .env.example =======================
    copy /y ".env.example" ".env" >nul
    echo.
    echo   [ACCION REQUERIDA] Abri server\.env y pone una clave en
    echo   HEARDY_API_KEY. Podes generar una con:
    echo.
    echo       make-key.bat
    echo.
)

echo ====================================================================
echo  Listo. Ahora:
echo    1) make-key.bat   (si aun no pusiste HEARDY_API_KEY en .env)
echo    2) run.bat        (arranca proveedor de PO tokens + API)
echo    3) health.bat     (comprueba que responde)
echo ====================================================================
endlocal
