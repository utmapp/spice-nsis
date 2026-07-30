@echo off
rem ===========================================================================
rem  Uninstall-VirtioGpu.cmd - removes the VirtIO GPU display drivers.
rem  Double-click to run. Self-contained: the PowerShell payload below is
rem  extracted to a temp file, run, and deleted.
rem ===========================================================================
setlocal
set "PSFILE=%SystemRoot%\Temp\Uninstall-VirtioGpu.ps1"

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$l = Get-Content -LiteralPath '%~f0'; $i = [Array]::IndexOf($l, ':::PS:::'); Set-Content -LiteralPath '%PSFILE%' -Value $l[($i+1)..($l.Count-1)] -Encoding UTF8"
if not exist "%PSFILE%" (
    echo Failed to extract the script payload.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
exit /b %errorlevel%

:::PS:::
<#
Uninstalls the VirtIO GPU display drivers (viogpudo and viogpu3d): removes
their driver packages from the driver store and cleans up the services they
installed.

Runs in two phases because viogpudo cannot be unloaded safely. Its release
path resets the virtio device in an unbounded loop while holding the PnP
engine lock, so removing or disabling a loaded instance never returns and
hangs the machine. Instead the driver is never unloaded: phase 1 disables the
service and reboots, so the driver is not loaded at all on the next boot, and
phase 2 removes the packages then, when there is nothing to tear down.

Phase 2 runs automatically from a one-shot scheduled task at startup.

The display keeps working throughout. With no VirtIO GPU driver, Windows
drives the firmware framebuffer with its basic display driver, at reduced
resolution.

Architecture-neutral: ARM64 and x64 use the same driver, service and device
names, and only in-box tools are used.
#>
param([ValidateSet(1, 2)][int]$Phase = 1)

$ErrorActionPreference = 'Stop'

$TaskName    = 'UninstallVirtioGpuPhase2'
$ScriptPath  = $PSCommandPath
$LogFile     = Join-Path $env:SystemRoot 'Temp\Uninstall-VirtioGpu.log'
$TargetInfs  = @('viogpudo.inf', 'viogpu3d.inf')
$TargetSvcs  = @('VioGpuDod', 'VioGpu3D')

function Log([string]$Message) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

# Native tools write to stderr on benign conditions (for example schtasks
# /Delete on a task that does not exist). With ErrorActionPreference = Stop
# that would abort the script, so run them with errors demoted.
function Invoke-Tool([string]$Exe, [string[]]$Arguments, [switch]$Quiet) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        if (-not $Quiet) { $out | ForEach-Object { Log "    $_" } }
        , @($out)
    } finally { $ErrorActionPreference = $prev }
}

# Driver packages in the store. Get-WindowsDriver is language-independent;
# pnputil output is parsed only if it is unavailable.
function Get-Packages {
    $found = @()
    try {
        $found = Get-WindowsDriver -Online -ErrorAction Stop |
            Where-Object { $TargetInfs -contains (Split-Path $_.OriginalFileName -Leaf) } |
            ForEach-Object {
                [pscustomobject]@{
                    Published = $_.Driver
                    Original  = Split-Path $_.OriginalFileName -Leaf
                    Version   = $_.Version
                }
            }
    } catch {
        $cur = $null
        foreach ($line in ((Invoke-Tool 'pnputil.exe' @('/enum-drivers') -Quiet) -split "`r?`n")) {
            if ($line -match ':\s*(oem\d+\.inf)\s*$') {
                if ($cur) { $found += $cur }
                $cur = [pscustomobject]@{ Published = $Matches[1]; Original = $null; Version = $null }
            } elseif ($cur -and -not $cur.Original -and $line -match ':\s*(\S+\.inf)\s*$') {
                $cur.Original = $Matches[1]
            }
        }
        if ($cur) { $found += $cur }
        $found = $found | Where-Object { $TargetInfs -contains $_.Original }
    }
    , @($found)
}

# Devices bound to one of these drivers. The service name is read from the
# device: it is VioGpuDod / VioGpu3D and never matches the .sys file name.
function Get-BoundDevices {
    $devs = @()
    foreach ($d in (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)) {
        $svc = $null
        try {
            $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                    -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop).Data
        } catch { }
        if ($svc -and ($TargetSvcs -contains $svc)) {
            $devs += [pscustomobject]@{
                Name    = $d.FriendlyName
                Service = $svc
                Status  = $d.Status
                Present = ($d.Status -ne 'Unknown')
            }
        }
    }
    , @($devs)
}

function Remove-Packages {
    foreach ($p in (Get-Packages)) {
        Log "Removing $($p.Published) ($($p.Original))"
        Invoke-Tool 'pnputil.exe' @('/delete-driver', $p.Published, '/uninstall') | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Invoke-Tool 'pnputil.exe' @('/delete-driver', $p.Published, '/uninstall', '/force') | Out-Null
        }
    }
}

# A service key outlives the package that created it. Left disabled it would
# silently break a later install of the same driver, so drop the orphans.
function Remove-OrphanServices {
    $left = Get-Packages
    foreach ($svc in $TargetSvcs) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path $key)) { continue }
        $inf = if ($svc -eq 'VioGpuDod') { 'viogpudo.inf' } else { 'viogpu3d.inf' }
        if ($left | Where-Object { $_.Original -eq $inf }) {
            Set-ItemProperty -LiteralPath $key -Name Start -Value 3 -Type DWord
            Log "Service $svc still has a package; start type restored"
        } else {
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
            Log "Removed service $svc"
        }
    }
}

function Invoke-Purge {
    foreach ($svc in $TargetSvcs) {
        $q = Invoke-Tool 'sc.exe' @('query', $svc) -Quiet
        if ($LASTEXITCODE -eq 0 -and ($q -match 'RUNNING')) {
            throw "$svc is running; the machine must be rebooted before the packages can be removed."
        }
    }
    Remove-Packages
    Remove-OrphanServices
    Invoke-Tool 'schtasks.exe' @('/Delete', '/TN', $TaskName, '/F') -Quiet | Out-Null
}

function Invoke-Phase1 {
    $packages = Get-Packages
    $devices  = Get-BoundDevices
    $loaded   = @($devices | Where-Object Present)

    Write-Host ''
    Write-Host 'Uninstall VirtIO GPU display drivers'
    Write-Host '------------------------------------'
    if (-not $packages -and -not $loaded) {
        Write-Host 'No VirtIO GPU drivers are installed. Nothing to do.'
        Read-Host 'Press Enter to close'
        return 0
    }

    Write-Host 'Found:'
    foreach ($p in $packages) { Write-Host "  package  $($p.Original)  version $($p.Version)  ($($p.Published))" }
    foreach ($d in $loaded)   { Write-Host "  device   $($d.Name)  service $($d.Service)" }
    Write-Host ''
    Write-Host 'This will:'
    if ($loaded) {
        Write-Host "  1. Disable the display driver service ($($loaded.Service -join ', '))."
        Write-Host '  2. Restart this computer NOW.'
        Write-Host '  3. Remove the driver packages automatically after the restart.'
        Write-Host ''
        Write-Host 'The restart is required: the driver cannot be removed while it is loaded.'
    } else {
        Write-Host '  1. Remove the driver packages now. No restart is needed.'
    }
    Write-Host ''
    Write-Host 'The screen keeps working, at a lower resolution, until a display driver is installed.'
    Write-Host 'Save your work before continuing.'
    Write-Host ''

    if ((Read-Host 'Type YES to continue') -ne 'YES') {
        Write-Host 'Cancelled. Nothing was changed.'
        Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
        Read-Host 'Press Enter to close'
        return 1
    }

    if (-not $loaded) {
        Invoke-Purge
        Log 'Done.'
        Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
        Read-Host 'Press Enter to close'
        return 0
    }

    foreach ($svc in ($loaded.Service | Select-Object -Unique)) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -Type DWord
        if ((Get-ItemProperty -LiteralPath $key -Name Start).Start -ne 4) {
            throw "Could not disable service $svc."
        }
        Log "Disabled service $svc"
    }

    Invoke-Tool 'schtasks.exe' @('/Create', '/TN', $TaskName, '/TR',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Phase 2",
        '/SC', 'ONSTART', '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F') -Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not schedule the second phase.' }
    Log 'Scheduled removal for the next start'

    Write-Host ''
    Write-Host 'Restarting now...'
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    return 0
}

function Invoke-Phase2 {
    Log 'Phase 2: removing driver packages'
    Invoke-Purge
    Log 'Done.'
    Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
    return 0
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required.'
    }
    if ($Phase -eq 1) { exit (Invoke-Phase1) } else { exit (Invoke-Phase2) }
} catch {
    Log "ERROR: $($_.Exception.Message)"
    if ($Phase -eq 1) { Read-Host 'Press Enter to close' }
    exit 1
}
