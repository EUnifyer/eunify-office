<#
.SYNOPSIS
  Package the built EUnifyer Office (LibreOffice fork) into Windows artifacts:
  a portable .zip (always) and an .msi (when the WiX Toolset is on PATH).

.DESCRIPTION
  The install layout is fixed at "%ProgramFiles%\EUnifyer Office" so that
  eunify-desktop's office.rs can detect it:
    <ProgramFiles>\EUnifyer Office\program\soffice.exe   <- launcher
    <ProgramFiles>\EUnifyer Office\version               <- read by office.rs

  Run on a Windows build host / CI runner after the LibreOffice build has
  produced libreoffice\instdir.

.PARAMETER Version
  Version string written into the bundle and artifact names. Default 1.0.0.
#>
[CmdletBinding()]
param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$InstDir   = Join-Path $RootDir "libreoffice\instdir"
$OutputDir = Join-Path $RootDir "dist"
$AppName   = "EUnifyer Office"
$StageDir  = Join-Path $OutputDir ".win-stage"
$AppStage  = Join-Path $StageDir $AppName

Write-Host ">> Packaging EUnifyer Office for Windows (v$Version)..."

if (-not (Test-Path (Join-Path $InstDir "program"))) {
    Write-Error "instdir\program not found at $InstDir — build EUnifyer Office first."
}

if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $AppStage | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---------- 1. Stage the install tree ----------

Write-Host ">> Staging '$AppName'..."
Copy-Item -Recurse -Force (Join-Path $InstDir "*") $AppStage

# version file — read by eunify-desktop office.rs
Set-Content -Path (Join-Path $AppStage "version") -Value $Version -NoNewline

# ---------- 2. Portable .zip ----------

Write-Host ">> Building portable .zip..."
$Zip = Join-Path $OutputDir "EUnifyer-Office-$Version-windows-x64.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $AppStage -DestinationPath $Zip
Write-Host "   $Zip"

# ---------- 3. .msi via WiX (optional) ----------

$wixCandle = Get-Command candle.exe -ErrorAction SilentlyContinue
$wixLight  = Get-Command light.exe  -ErrorAction SilentlyContinue
$wixHeat   = Get-Command heat.exe   -ErrorAction SilentlyContinue

if ($wixCandle -and $wixLight -and $wixHeat) {
    Write-Host ">> Building .msi with WiX Toolset..."
    $wxsDir = Join-Path $StageDir "wix"
    New-Item -ItemType Directory -Force -Path $wxsDir | Out-Null

    # Harvest the staged tree into a component group.
    & heat.exe dir $AppStage -cg OfficeFiles -dr INSTALLFOLDER -srd -scom -sreg -sfrag -gg `
        -var var.SourceDir -out (Join-Path $wxsDir "files.wxs")

    $productWxs = Join-Path $wxsDir "product.wxs"
    @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="EUnifyer Office" Language="1033" Version="$Version"
           Manufacturer="EUnifyer" UpgradeCode="6F3A2C1E-4B8D-4E2A-9C7F-1A2B3C4D5E6F">
    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine" />
    <MajorUpgrade DowngradeErrorMessage="A newer version of EUnifyer Office is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFiles64Folder">
        <Directory Id="INSTALLFOLDER" Name="EUnifyer Office" />
      </Directory>
    </Directory>
    <Feature Id="Main" Title="EUnifyer Office" Level="1">
      <ComponentGroupRef Id="OfficeFiles" />
    </Feature>
  </Product>
</Wix>
"@ | Set-Content -Path $productWxs -Encoding UTF8

    & candle.exe -arch x64 -dSourceDir="$AppStage" `
        -out (Join-Path $wxsDir "\") $productWxs (Join-Path $wxsDir "files.wxs")
    $Msi = Join-Path $OutputDir "EUnifyer-Office-$Version-windows-x64.msi"
    & light.exe -out $Msi (Join-Path $wxsDir "product.wixobj") (Join-Path $wxsDir "files.wixobj")
    Write-Host "   $Msi"
} else {
    Write-Host ">> WiX Toolset (candle/light/heat) not found — skipping .msi."
    Write-Host "   Install with: dotnet tool install --global wix  (or choco install wixtoolset)"
}

Remove-Item -Recurse -Force $StageDir
Write-Host ">> Windows packaging complete. Artifacts in $OutputDir\"
Get-ChildItem $OutputDir -Filter "*windows*" | Select-Object Name | Format-Table -HideTableHeaders
