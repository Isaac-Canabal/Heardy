@echo off
REM Corre la suite de tests del servidor (pytest). No hace falta setup.bat
REM completo: si .venv no existe, este script instala solo lo necesario
REM para testear (requirements-dev.txt), no yt-dlp ni el proveedor de PO
REM tokens.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo Creando entorno virtual para tests...
    py -m venv .venv
    if errorlevel 1 (
        echo [ERROR] No se pudo crear el entorno virtual.
        exit /b 1
    )
)

call ".venv\Scripts\python.exe" -m pip install --quiet -r requirements-dev.txt
if errorlevel 1 (
    echo [ERROR] Fallo la instalacion de dependencias de test.
    exit /b 1
)

call ".venv\Scripts\python.exe" -m pytest %*
endlocal
