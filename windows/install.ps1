# Builds dictate.exe with the in-box .NET Framework compiler and registers it to start at logon.
param([string]$Server = "http://localhost:8000")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $env:LOCALAPPDATA "dictate"
$cfgDir = Join-Path $env:APPDATA "dictate"
New-Item -ItemType Directory -Force $bin, $cfgDir | Out-Null

Get-Process dictate -ErrorAction SilentlyContinue | Stop-Process -Force
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
& $csc /nologo /target:winexe /optimize "/out:$bin\dictate.exe" `
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "$here\Dictate.cs"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

$cfg = Join-Path $cfgDir "config.json"
if (-not (Test-Path $cfg)) {
  (Get-Content -Raw "$here\config.example.json").Replace("__SERVER__", $Server) | Set-Content -Encoding utf8 $cfg
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute "$bin\dictate.exe"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "Dictate" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName "Dictate"
Write-Host "Installed $bin\dictate.exe; config $cfg; log $cfgDir\dictate.log"
