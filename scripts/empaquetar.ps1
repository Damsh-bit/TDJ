# Arma dist\TiempoDeJuego-paquete.zip para pasarle a los amigos:
#   TiempoDeJuego\  (el addon)
#   Subidor\        (con config.json, que lleva la clave del grupo)
#   LEEME.txt
$raiz = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$config = Join-Path $raiz 'subidor\config.json'
if (-not (Test-Path $config)) { throw "Falta subidor\config.json (copiá config.ejemplo.json y poné la clave del grupo)." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("tdj-paquete-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force "$tmp\Subidor" | Out-Null
Copy-Item -Recurse (Join-Path $raiz 'addon\TiempoDeJuego') $tmp
foreach ($a in 'subir.ps1', 'instalar.bat', 'instalar.ps1', 'oculto.vbs', 'desinstalar.bat', 'config.json') {
    Copy-Item (Join-Path $raiz "subidor\$a") "$tmp\Subidor\"
}
Copy-Item (Join-Path $raiz 'scripts\LEEME.txt') $tmp

$dist = Join-Path $raiz 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist 'TiempoDeJuego-paquete.zip'
Compress-Archive -Path "$tmp\*" -DestinationPath $zip -Force
Remove-Item -Recurse -Force $tmp
Write-Host "Listo: $zip"
