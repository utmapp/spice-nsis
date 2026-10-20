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

Services are removed through the service control manager, never by deleting
their registry keys, and if the SCM defers a delete to the next boot the
uninstall insists on that restart. A record the SCM still holds after its
key is gone makes the next install of the same driver fail; see
Remove-ServiceRecord.

The display keeps working throughout. With no VirtIO GPU driver, Windows
drives the firmware framebuffer with its basic display driver, at reduced
resolution. Older installers turned that fallback off, which would leave the
screen black once the driver is gone, so it is turned back on first; see
Enable-BasicDisplayFallback.

Architecture-neutral: ARM64 and x64 use the same driver, service and device
names, and only in-box tools are used.
#>
param([ValidateSet(1, 2)][int]$Phase = 1)

$ErrorActionPreference = 'Stop'

$TaskName    = 'UninstallVirtioGpuPhase2'
$ScriptPath  = $PSCommandPath
$LogFile     = Join-Path $env:SystemRoot 'Temp\Uninstall-VirtioGpu.log'
$ServiceInf  = [ordered]@{ 'VioGpuDod' = 'viogpudo.inf'; 'VioGpu3D' = 'viogpu3d.inf' }
$TargetInfs  = @($ServiceInf.Values)
$TargetSvcs  = @($ServiceInf.Keys)
$BddKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\BasicDisplay'
$BddValue    = 'DisableBasicDisplayFallback'

# sc.exe exits with the Win32 error code of the call that failed.
$ERROR_FILE_NOT_FOUND            = 2
$ERROR_SERVICE_DOES_NOT_EXIST    = 1060
$ERROR_SERVICE_MARKED_FOR_DELETE = 1072

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

# Older installers set DisableBasicDisplayFallback so that Windows would not
# fall back to the firmware framebuffer next to the VirtIO GPU. With the
# driver gone that leaves no display at all, so the value has to go before
# the restart that unloads the driver. Like the old uninstaller, drop the key
# too if nothing else is in it. Takes effect on the next boot.
function Test-BasicDisplayFallbackDisabled {
    $v = Get-ItemProperty -LiteralPath $BddKey -Name $BddValue -ErrorAction SilentlyContinue
    [bool]($v -and $v.$BddValue)
}

function Enable-BasicDisplayFallback {
    if (-not (Test-BasicDisplayFallbackDisabled)) { return }
    Remove-ItemProperty -LiteralPath $BddKey -Name $BddValue -Force
    $key = Get-Item -LiteralPath $BddKey -ErrorAction SilentlyContinue
    if ($key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
        Remove-Item -LiteralPath $BddKey -Force -ErrorAction SilentlyContinue
    }
    if (Test-BasicDisplayFallbackDisabled) { throw 'Could not re-enable the basic display fallback.' }
    Log 'Re-enabled the basic display fallback'
}

# Where a service stands with the SCM, which is not the same question as
# whether its registry key exists:
#
#   Absent   the SCM does not know it and no key is left behind
#   Present  a real, fully described service
#   Pending  the SCM still holds a record that cannot be completed away
#            until the machine restarts -- either marked for delete, or a
#            record whose registry key is already gone
function Get-ServiceState([string]$Name) {
    Invoke-Tool 'sc.exe' @('query', $Name) -Quiet | Out-Null
    $code = $LASTEXITCODE
    $key  = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if ($code -eq $ERROR_SERVICE_DOES_NOT_EXIST) {
        if ($key) { return 'Present' }   # key written, SCM not yet aware
        return 'Absent'
    }
    if ($code -eq $ERROR_SERVICE_MARKED_FOR_DELETE) { return 'Pending' }
    if ($code -eq $ERROR_FILE_NOT_FOUND) { return 'Pending' }
    if ($code -eq 0 -and $key) { return 'Present' }
    return 'Pending'
}

# A service key outlives the package that created it. Left behind it would
# silently break a later install of the same driver, so drop the orphans --
# but never by deleting the key.
#
# Deleting the key directly leaves the SCM holding an in-memory record of a
# service whose configuration is gone. The next INF install then opens that
# record successfully and its QueryServiceConfig fails with
# ERROR_FILE_NOT_FOUND instead of ERROR_SERVICE_DOES_NOT_EXIST, so setupapi
# never takes the "create the service" path: it aborts AddService, rolls the
# install back and binds a NULL driver. The device is left as an unclassed
# Video Controller with no problem code -- healthy looking, and with no
# driver. Only a restart clears the record, so go through the SCM and, when
# it defers the delete, make sure the restart happens.
function Remove-ServiceRecord([string]$Name) {
    if ((Get-ServiceState $Name) -eq 'Absent') { return $true }

    Invoke-Tool 'sc.exe' @('delete', $Name) | Out-Null
    $code = $LASTEXITCODE

    # The SCM never knew about it, so nothing holds a reference to the key
    # and removing it by hand cannot strand a record.
    if ($code -eq $ERROR_SERVICE_DOES_NOT_EXIST) {
        Remove-Item -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" `
            -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ((Get-ServiceState $Name) -eq 'Absent') {
        Log "Removed service $Name"
        return $true
    }
    if ($code -eq 0 -or $code -eq $ERROR_SERVICE_MARKED_FOR_DELETE) {
        Log "Service $Name is deleted but still held by the service manager"
    } else {
        Log "Could not remove service $Name (sc delete returned $code)"
    }
    return $false
}

# Returns the services whose removal the SCM deferred to the next restart.
function Remove-OrphanServices {
    $left    = Get-Packages
    $pending = @()
    foreach ($svc in $TargetSvcs) {
        if ($left | Where-Object { $_.Original -eq $ServiceInf[$svc] }) {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
            if (Test-Path $key) {
                Set-ItemProperty -LiteralPath $key -Name Start -Value 3 -Type DWord
                Log "Service $svc still has a package; start type restored"
            }
            continue
        }
        if (-not (Remove-ServiceRecord $svc)) { $pending += $svc }
    }
    , @($pending)
}

# Returns the services the SCM will only let go of on the next restart.
function Invoke-Purge {
    foreach ($svc in $TargetSvcs) {
        $q = Invoke-Tool 'sc.exe' @('query', $svc) -Quiet
        if ($LASTEXITCODE -eq 0 -and ($q -match 'RUNNING')) {
            throw "$svc is running; the machine must be rebooted before the packages can be removed."
        }
    }
    Enable-BasicDisplayFallback
    Remove-Packages
    $pending = Remove-OrphanServices
    Invoke-Tool 'schtasks.exe' @('/Delete', '/TN', $TaskName, '/F') -Quiet | Out-Null
    , @($pending)
}

# shutdown.exe rather than Restart-Computer: it states the reason on screen
# and leaves a grace period, so a restart that happens without the user
# asking for one is at least announced and can be stopped with 'shutdown /a'.
function Request-Restart([string]$Reason) {
    Log "Restarting in 60 seconds: $Reason"
    Invoke-Tool 'shutdown.exe' @('/r', '/t', '60', '/c', $Reason) | Out-Null
}

# The SCM will not let go until the next boot, and a driver installed before
# then fails in AddService. Offer the restart rather than describe it.
function Resolve-Pending([string[]]$Pending) {
    Write-Host ''
    Write-Host "The service manager still holds a deleted service ($($Pending -join ', '))."
    Write-Host 'It only lets go on a restart. A display driver installed before then'
    Write-Host 'would fail to install and leave the display device with no driver.'
    Write-Host ''
    if ((Read-Host 'Type YES to restart now') -eq 'YES') {
        Request-Restart 'Finishing the VirtIO GPU uninstall.'
        return
    }
    Write-Host 'Restart this computer before installing a display driver.'
}

function Invoke-Phase1 {
    $packages = Get-Packages
    $devices  = Get-BoundDevices
    $loaded   = @($devices | Where-Object Present)
    $stale    = @()
    foreach ($svc in $TargetSvcs) {
        if ((Get-ServiceState $svc) -eq 'Absent') { continue }
        if ($loaded.Service -contains $svc) { continue }
        if ($packages | Where-Object { $_.Original -eq $ServiceInf[$svc] }) { continue }
        $stale += $svc
    }
    $noBdd = Test-BasicDisplayFallbackDisabled

    Write-Host ''
    Write-Host 'Uninstall VirtIO GPU display drivers'
    Write-Host '------------------------------------'
    if (-not $packages -and -not $loaded -and -not $stale -and -not $noBdd) {
        Write-Host 'No VirtIO GPU drivers are installed. Nothing to do.'
        $null = Read-Host 'Press Enter to close'
        return 0
    }

    Write-Host 'Found:'
    foreach ($p in $packages) { Write-Host "  package  $($p.Original)  version $($p.Version)  ($($p.Published))" }
    foreach ($d in $loaded)   { Write-Host "  device   $($d.Name)  service $($d.Service)" }
    foreach ($svc in $stale)  { Write-Host "  service  $svc  (left over from an earlier uninstall)" }
    if ($noBdd)               { Write-Host '  setting  basic display fallback disabled  (set by an older installer)' }
    Write-Host ''
    Write-Host 'This will:'
    $steps = @()
    if ($noBdd) { $steps += 'Re-enable the basic display fallback.' }
    if ($loaded) {
        $steps += "Disable the display driver service ($($loaded.Service -join ', '))."
        $steps += 'Restart this computer NOW.'
        $steps += 'Remove the driver packages automatically after the restart.'
    } elseif ($packages) {
        $steps += 'Remove the driver packages now.'
    } elseif ($stale) {
        $steps += 'Clear the leftover service records now.'
    }
    for ($i = 0; $i -lt $steps.Count; $i++) { Write-Host "  $($i + 1). $($steps[$i])" }
    if ($loaded) {
        Write-Host ''
        Write-Host 'The restart is required: the driver cannot be removed while it is loaded.'
    }
    Write-Host ''
    Write-Host 'The screen keeps working, at a lower resolution, until a display driver is installed.'
    Write-Host 'Save your work before continuing.'
    Write-Host ''

    if ((Read-Host 'Type YES to continue') -ne 'YES') {
        Write-Host 'Cancelled. Nothing was changed.'
        Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
        $null = Read-Host 'Press Enter to close'
        return 1
    }

    if (-not $loaded) {
        $pending = Invoke-Purge
        Log 'Done.'
        Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
        if ($pending) {
            Resolve-Pending $pending
        } elseif ($noBdd) {
            Write-Host 'Restart this computer for the basic display fallback to take effect.'
        }
        $null = Read-Host 'Press Enter to close'
        return 0
    }

    # Before the restart, or the machine comes back with no display at all.
    Enable-BasicDisplayFallback

    foreach ($svc in ($loaded.Service | Select-Object -Unique)) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path $key)) { throw "Service $svc has no configuration to disable." }
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
    $pending = Invoke-Purge
    Log 'Done.'
    Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
    if ($pending) {
        # Nothing in this session can flush the record and there is no one to
        # ask -- this runs as SYSTEM at startup -- while leaving it would
        # break the next driver install. The scheduled task has already been
        # deleted above, so this cannot turn into a restart loop.
        Log "Service manager still holds $($pending -join ', ')"
        Request-Restart 'Finishing the VirtIO GPU uninstall.'
    }
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
    if ($Phase -eq 1) { $null = Read-Host 'Press Enter to close' }
    exit 1
}
