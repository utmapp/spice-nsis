# Builds utm-guest-tools-<version>.exe and utm-guest-tools-<version>.iso
#
#   .\build-iso.ps1 <version>
#
# Requires NSIS and the Windows ADK Deployment Tools (oscdimg).

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$MakeNsis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
$Oscdimg = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
$Installer = "utm-guest-tools-$Version.exe"
$IsoImage = "utm-guest-tools-$Version.iso"
$IsoLabel = "UTM Guest Tools"
$Staging = Join-Path $env:TEMP "utm-guest-tools-iso"

# Build the installer
$env:VERSION = $Version
& $MakeNsis -DSPICE win-guest-tools.nsis
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $Installer)) { throw "$Installer was not created" }

# Stage the ISO contents
if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
New-Item -ItemType Directory $Staging | Out-Null
Copy-Item -Recurse "drivers\virtio" (Join-Path $Staging "Drivers")
Get-ChildItem -Recurse (Join-Path $Staging "Drivers") -Filter *.pdb | Remove-Item -Force
Copy-Item "Autounattend.xml", "Uninstall-VirtioGpu.cmd", "virtio-win_license.txt" $Staging
Copy-Item $Installer (Join-Path $Staging "utm-guest-tools.exe")

# Build the ISO
if (Test-Path $IsoImage) { Remove-Item -Force $IsoImage }
& $Oscdimg -m -o -u2 -udfver102 "-l$IsoLabel" $Staging $IsoImage
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE" }

Remove-Item -Recurse -Force $Staging
Write-Host "Built $Installer and $IsoImage"
