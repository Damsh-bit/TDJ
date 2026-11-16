# Tiempo de Juego - subidor v2.3
# Windows lo corre solo cada 5 minutos (ver instalar.bat).
# - Mientras el juego esta abierto, cada minuto:
#     * manda a la web una ESTIMACION de lo jugado hoy (lo ultimo que guardo el
#       addon + el tiempo que paso desde entonces) y la marca de "jugando ahora";
#     * si el addon guardo algo nuevo (un /reload, cambio de personaje), lo sube.
# - Al cerrar el juego, sube el dato exacto que guardo el addon.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $aqui 'subir.log'
$estadoArchivo = Join-Path $aqui 'ultimo.txt'
function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -Path $log -Encoding UTF8
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

    function Subir($filas, [bool]$vivo, [bool]$cerrado = $false) {
        $cuerpo = [pscustomobject]@{ id = $id; vivo = $vivo; cerrado = $cerrado; filas = @($filas | ForEach-Object { [pscustomobject]$_ }) }
        $json = ConvertTo-Json -InputObject $cuerpo -Compress -Depth 4
        if ($env:TDJ_PRUEBA) { $json; return }  # modo prueba: mostrar sin subir
        Invoke-RestMethod -Method Post -Uri "$($cfg.web.TrimEnd('/'))/api/subir" `
            -Headers @{ 'x-clave-grupo' = $cfg.claveGrupo } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    }

    function Archivos-Addon {
        $out = @()
        foreach ($r in $raices) { $out += @(Get-ChildItem -Path "$r\*\WTF\Account\*\SavedVariables\TiempoDeJuego.lua" -ErrorAction SilentlyContinue) }
        return $out
    }

    # Lee el archivo del addon: filas exportadas y hora de reinicio del dia
    function Leer-Addon($archivo) {
        $txt = [IO.File]::ReadAllText($archivo.FullName, [Text.Encoding]::UTF8)
        $filas = @()
        if ($txt -match '\["export"\]\s*=\s*"([^"]*)"') {
            foreach ($reg in ($Matches[1] -split '~')) { $f = Convertir-Fila $reg; if ($f) { $filas += $f } }
        }
        $hora = 6
        if ($txt -match '\["horaReinicio"\]\s*=\s*(\d+)') { $hora = [int]$Matches[1] }
        [pscustomobject]@{ filas = $filas; horaReinicio = $hora; guardado = $archivo.LastWriteTime }
    }

    # ---- Subida exacta desde el archivo del addon (solo si cambio desde la ultima vez) ----
    function Subir-Guardado([bool]$cerrado = $false) {
        $archivos = Archivos-Addon
        if ($archivos.Count -eq 0) {
            if ($raices.Count -eq 0) { Log 'No encontré la carpeta de WoW. Ponela en config.json (carpetaWow).' }
            else { Log 'Todavía no hay datos del addon: aparecen la primera vez que cerrás el juego o hacés /reload con el addon instalado.' }
            return
        }
        $huella = ($archivos | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        $igual = (Test-Path $estadoArchivo) -and ((Get-Content $estadoArchivo -Raw).Trim() -eq $huella)
        if ($igual -and -not $cerrado -and -not $env:TDJ_PRUEBA) { return }

        $filas = @{}
        foreach ($a in $archivos) {
            foreach ($f in (Leer-Addon $a).filas) {
                $k = "$($f.persona)|$($f.dia)"
                $prev = $filas[$k]
                if (-not $prev -or ($f.fuente -eq 'propio' -and $prev.fuente -ne 'propio') -or
                    ($f.fuente -eq $prev.fuente -and $f.segundos -gt $prev.segundos)) { $filas[$k] = $f }
            }
        }
        if ($filas.Count -eq 0) { Log 'El archivo del addon todavía no tiene datos (cerrá el juego o hacé /reload una vez).'; return }

        Subir $filas.Values $false $cerrado
        if (-not $env:TDJ_PRUEBA) {
            Set-Content -Path $estadoArchivo -Value $huella -Encoding UTF8
            if (-not $igual) { Log "Subidas $($filas.Count) filas del archivo del addon." }
        }
    }

    # ---- Estimacion "en vivo" de hoy ----
    # Lo ultimo que guardo el addon para hoy + el tiempo que paso desde que se guardo
    # (o desde que se abrio el juego, o desde que empezo el dia, lo que sea mas reciente).
    function Estimar-Vivo($inicioJuego) {
        $archivos = @(Archivos-Addon | Sort-Object LastWriteTime -Descending)
        if ($archivos.Count -eq 0) { return $null }
        $datos = Leer-Addon $archivos[0]
        $propias = @($datos.filas | Where-Object { $_.fuente -eq 'propio' } | Sort-Object { $_.dia })
        if ($propias.Count -eq 0) { return $null }  # sin datos propios no sabemos tu nombre

        $ahora = Get-Date
        $inicioDia = $ahora.Date.AddHours($datos.horaReinicio)
        if ($ahora -lt $inicioDia) { $inicioDia = $inicioDia.AddDays(-1) }
        $hoy = $inicioDia.ToString('yyyy-MM-dd')

        $ultima = $propias[-1]
        $deHoy = $propias | Where-Object { $_.dia -eq $hoy } | Select-Object -First 1
        $base = if ($deHoy) { $deHoy.segundos } else { 0 }
        $desde = @($datos.guardado, $inicioJuego, $inicioDia) | Sort-Object | Select-Object -Last 1
        $estimado = [int][math]::Min(86400, $base + [math]::Max(0, ($ahora - $desde).TotalSeconds))

        [ordered]@{ persona = $ultima.persona; dia = $hoy; segundos = $estimado; nivel = $ultima.nivel
                    personaje = $ultima.personaje; clase = $ultima.clase; limite_semanal = $ultima.limite_semanal }
    }

    function Inicio-Juego {
        if ($env:TDJ_PRUEBA_VIVO) { return (Get-Date).AddMinutes(-20) }  # para probar sin abrir el juego
        $p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Wow' })
        if ($p.Count -eq 0) { return $null }
        return ($p | ForEach-Object { $_.StartTime } | Sort-Object | Select-Object -First 1)
    }

    # ---- Mientras el juego este abierto ----
    $inicio = Inicio-Juego
    if ($inicio) {
        $ultimoLog = [datetime]::MinValue
        while ($inicio) {
            try {
                $fila = Estimar-Vivo $inicio
                if ($fila) {
                    Subir @($fila) $true
                    if (((Get-Date) - $ultimoLog).TotalMinutes -ge 15) {
                        Log "En vivo: $($fila.persona) ~$([math]::Round($fila.segundos / 60)) min hoy (estimado)."
                        $ultimoLog = Get-Date
                    }
                }
                Subir-Guardado
            } catch { Log "ERROR en vivo: $($_.Exception.Message) $($_.ErrorDetails.Message)" }
            if ($env:TDJ_PRUEBA) { break }
            Start-Sleep -Seconds 60
            $inicio = Inicio-Juego
        }
        if (-not $env:TDJ_PRUEBA) {
            Start-Sleep -Seconds 15  # le da tiempo al juego a guardar al cerrar
            Subir-Guardado $true      # dato exacto y deja de figurar "jugando ahora"
            exit 0
        }
    }

    Subir-Guardado
}
catch {
    Log "ERROR: $($_.Exception.Message) $($_.ErrorDetails.Message)"
    exit 1
}
finally {
    $mutex.ReleaseMutex()
}
