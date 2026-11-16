# Programa la subida automatica cada 5 minutos.
# Corre aunque la notebook este a bateria y nunca abre ventanas.
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$nombre = 'TiempoDeJuego subir'

$accion = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$aqui\oculto.vbs`""
$disparador = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 16)

Unregister-ScheduledTask -TaskName $nombre -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $nombre -Action $accion -Trigger $disparador -Settings $ajustes `
    -Description 'Sube las horas de Tiempo de Juego (WoW) a la web.' | Out-Null
Write-Host '  Subida automatica programada cada 5 minutos.'
