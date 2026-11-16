# Tiempo de Juego - subidor v2
# Windows lo corre solo cada 5 minutos (ver instalar.bat).
# - Mientras el juego esta abierto: cada minuto lee la ultima linea "TDJ:..." del
#   registro de chat (Logs\WoWChatLog.txt) y la manda a la web como dato "en vivo".
# - Cuando el juego esta cerrado: manda lo que el addon guardo en SavedVariables
#   (se escribe al cerrar el juego o con /reload).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $aqui 'subir.log'
$estadoArchivo = Join-Path $aqui 'ultimo.txt'
function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -Path $log -Encoding UTF8
    # El registro no crece para siempre: quedan las ultimas 300 lineas
    $lineas = @(Get-Content $log -Encoding UTF8)
    if ($lineas.Count -gt 400) { $lineas[-300..-1] | Set-Content $log -Encoding UTF8 }
}

# Una sola copia a la vez (la tarea corre cada 5 minutos y el modo en vivo dura mientras juegues)
$mutex = New-Object System.Threading.Mutex($false, 'Local\TiempoDeJuegoSubidor')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    $cfg = Get-Content (Join-Path $aqui 'config.json') -Raw | ConvertFrom-Json

    $idArchivo = Join-Path $aqui 'id.txt'
    if (-not (Test-Path $idArchivo)) { Set-Content -Path $idArchivo -Value ([guid]::NewGuid().ToString()) -Encoding ASCII }
    $id = (Get-Content $idArchivo -Raw).Trim()

    # Carpetas tipicas de WoW (o la de config.json)
    $raices = @()
    if ($cfg.carpetaWow) { $raices += $cfg.carpetaWow }
    $raices += @("${env:ProgramFiles(x86)}\World of Warcraft", "$env:ProgramFiles\World of Warcraft",
                 'C:\World of Warcraft', 'D:\World of Warcraft', 'D:\Games\World of Warcraft',
                 'E:\World of Warcraft', 'C:\Games\World of Warcraft')
    $raices = @($raices | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })

    # Convierte un registro "persona,dia,segundos,..." en una fila para la web.
    # Acepta el formato v1 (8 campos) y el v2 (14 campos, con estadisticas).
    function Convertir-Fila([string]$reg) {
        $c = $reg -split ','
        if ($c.Count -lt 8 -or $c[1] -notmatch '^\d{4}-\d{2}-\d{2}$') { return $null }
        $n = { param($i) if ($c.Count -gt $i -and $c[$i] -match '^\d+$') { [int64]$c[$i] } else { [int64]0 } }
        $v2 = $c.Count -ge 14
        [ordered]@{
            persona = $c[0]; dia = $c[1]
            segundos = [int][math]::Min(86400, (& $n 2)); nivel = [int](& $n 3)
            personaje = $(if ($c[4]) { $c[4] } else { $null }); clase = $(if ($c[5]) { $c[5] } else { $null })
            limite = $(if ($v2) { 0 } else { [int][math]::Min(86400, (& $n 6)) })
            limite_semanal = $(if ($v2) { [int][math]::Min(604800, (& $n 6)) } else { 0 })
            fuente = $(if ($c[7] -eq 'propio') { 'propio' } else { 'amigo' })
            misiones = [int](& $n 8); muertes = [int](& $n 9)
            oro_ganado = (& $n 10); oro_gastado = (& $n 11)
            kills = [int](& $n 12); xp = [int](& $n 13)
        }
    }

    function Subir($filas, [bool]$vivo) {
        $cuerpo = [pscustomobject]@{ id = $id; vivo = $vivo; filas = @($filas | ForEach-Object { [pscustomobject]$_ }) }
        $json = ConvertTo-Json -InputObject $cuerpo -Compress -Depth 4
        if ($env:TDJ_PRUEBA) { $json; return }  # modo prueba: mostrar sin subir
        Invoke-RestMethod -Method Post -Uri "$($cfg.web.TrimEnd('/'))/api/subir" `
            -Headers @{ 'x-clave-grupo' = $cfg.claveGrupo } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    }

    # Lee el final del registro de chat sin trabar al juego y devuelve la ultima linea "TDJ:"
    function Leer-Vivo {
        foreach ($r in $raices) {
            foreach ($archivo in @(Get-ChildItem -Path "$r\*\Logs\WoWChatLog.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                $fs = [IO.File]::Open($archivo.FullName, 'Open', 'Read', 'ReadWrite')
                try {
                    $largo = [math]::Min($fs.Length, 65536)
                    $fs.Seek(-$largo, 'End') | Out-Null
                    $buf = New-Object byte[] $largo
                    [void]$fs.Read($buf, 0, $largo)
                } finally { $fs.Close() }
                $m = [regex]::Matches([Text.Encoding]::UTF8.GetString($buf), 'TDJ:([^\s]+)')
                if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
            }
        }
        return $null
    }

    function Juego-Abierto {
        if ($env:TDJ_PRUEBA_VIVO) { return $true }  # para probar el modo en vivo sin abrir el juego
        [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Wow' })
    }

    # ---- Subida desde SavedVariables (lo que guarda el addon al cerrar, con /reload o al cambiar de personaje) ----
    # Devuelve $true si subio algo. Solo sube si el archivo cambio desde la ultima vez.
    function Subir-Guardado {
        $archivos = @()
        foreach ($r in $raices) {
            $archivos += @(Get-ChildItem -Path "$r\*\WTF\Account\*\SavedVariables\TiempoDeJuego.lua" -ErrorAction SilentlyContinue)
        }
        if ($archivos.Count -eq 0) {
            if ($raices.Count -eq 0) { Log 'No encontré la carpeta de WoW. Ponela en config.json (carpetaWow).' }
            else { Log 'Todavía no hay datos del addon: aparecen la primera vez que cerrás el juego o hacés /reload con el addon instalado.' }
            return $false
        }
        $huella = ($archivos | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        if ((Test-Path $estadoArchivo) -and ((Get-Content $estadoArchivo -Raw).Trim() -eq $huella) -and -not $env:TDJ_PRUEBA) { return $false }

        $filas = @{}
        foreach ($a in $archivos) {
            $txt = [IO.File]::ReadAllText($a.FullName, [Text.Encoding]::UTF8)
            if ($txt -notmatch '\["export"\]\s*=\s*"([^"]*)"') { continue }
            foreach ($reg in ($Matches[1] -split '~')) {
                $f = Convertir-Fila $reg
                if (-not $f) { continue }
                $k = "$($f.persona)|$($f.dia)"
                $prev = $filas[$k]
                if (-not $prev -or ($f.fuente -eq 'propio' -and $prev.fuente -ne 'propio') -or
                    ($f.fuente -eq $prev.fuente -and $f.segundos -gt $prev.segundos)) { $filas[$k] = $f }
            }
        }
        if ($filas.Count -eq 0) { Log 'El archivo del addon todavía no tiene datos (cerrá el juego o hacé /reload una vez).'; return $false }

        Subir $filas.Values $false
        if (-not $env:TDJ_PRUEBA) {
            Set-Content -Path $estadoArchivo -Value $huella -Encoding UTF8
            Log "Subidas $($filas.Count) filas del archivo del addon."
        }
        return $true
    }

    # ---- Mientras el juego esta abierto: cada minuto, lo en vivo del registro de chat
    #      y, si cambio, el archivo del addon (por ejemplo despues de un /reload) ----
    if (Juego-Abierto) {
        $ultimoVivo = ''
        $avisoSinVivo = $false
        $vueltas = 0
        while (Juego-Abierto) {
            try {
                $linea = Leer-Vivo
                if ($linea -and $linea -ne $ultimoVivo) {
                    $fila = Convertir-Fila $linea
                    if ($fila) { Subir @($fila) $true; $ultimoVivo = $linea; Log "En vivo: $($fila.persona) $([math]::Round($fila.segundos / 60)) min hoy." }
                } elseif (-not $linea -and -not $avisoSinVivo -and $vueltas -ge 5) {
                    Log 'En vivo: el registro de chat todavía no tiene datos del addon (se sube igual con cada /reload y al cerrar).'
                    $avisoSinVivo = $true
                }
                [void](Subir-Guardado)
            } catch { Log "ERROR en vivo: $($_.Exception.Message) $($_.ErrorDetails.Message)" }
            if ($env:TDJ_PRUEBA) { break }
            $vueltas++
            Start-Sleep -Seconds 60
        }
        if (-not $env:TDJ_PRUEBA) { Start-Sleep -Seconds 15 }  # le da tiempo al juego a guardar al cerrar
    }

    [void](Subir-Guardado)
}
catch {
    Log "ERROR: $($_.Exception.Message) $($_.ErrorDetails.Message)"
    exit 1
}
finally {
    $mutex.ReleaseMutex()
}
