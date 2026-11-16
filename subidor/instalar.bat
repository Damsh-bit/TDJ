@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  Tiempo de Juego - instalando el subidor de datos para la web
echo  ------------------------------------------------------------
echo.
if not exist "%~dp0config.json" (
  echo  Falta config.json en esta carpeta. Pedile el archivo al que armo el grupo.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1"
echo.
echo  Probando una subida ahora...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0subir.ps1"
echo.
echo  Listo. Si algo falla, mira el archivo subir.log en esta carpeta.
echo  Para desinstalar: desinstalar.bat
echo.
pause
