@echo off
REM Arranca el proveedor de PO tokens (aplicacion Node) en http://127.0.0.1:4416
REM
REM Tiene que quedarse corriendo mientras uses el servidor de descargas.
REM Sin el, YouTube devuelve 403 en la mayoria de videos.

setlocal
cd /d "%~dp0"

if not exist ".pot-provider\server\build\main.js" (
    echo [ERROR] El proveedor de PO tokens no esta compilado.
    echo         Ejecuta setup.bat primero.
    exit /b 1
)

echo Proveedor de PO tokens escuchando en http://127.0.0.1:4416
echo Deja esta ventana abierta. Ctrl+C para parar.
echo.
cd ".pot-provider\server"
node build\main.js
endlocal
