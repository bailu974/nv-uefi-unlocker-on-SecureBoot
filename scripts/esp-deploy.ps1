#requires -RunAsAdministrator
<#
.SYNOPSIS
  Copy the nv-uefi-unlocker EFI application plus its per-family assets onto the
  EFI System Partition, so the firmware can start it without a USB stick.

.DESCRIPTION
  The loader resolves its assets from the ROOT OF THE VOLUME IT WAS LOADED FROM
  (get_image_file_system(image_handle())), so the .bin files must sit at the ESP
  root -- not in a subdirectory.

  Expected layout after this script:

    ESP:\
      EFI\nvunlock\BOOTX64.EFI
      booter_load_ad102.bin
      gsp_boot_ad102.bin
      gsp_boot_desc_ad102.bin
      fwimage_ad102.bin
      fwsignature_ad102.bin
      scrubber_ad10x.bin
      v67-ad102-four-plm.bin      (only in unlock mode)
      i_know_what_i_am_doing.txt  (armed 5 s auto-run marker)

  Point Boot0000 at \EFI\nvunlock\BOOTX64.EFI afterwards (set-boot-entry.ps1) and
  add the file to your firmware's trusted list if Secure Boot is on.

.PARAMETER SourceDir
  Directory containing BOOTX64.EFI and the .bin assets (usually pkg\usbroot from
  make-usbroot.ps1, or a FAT32 stick that already works).

.PARAMETER TargetDir
  Directory on the ESP. Default \EFI\nvunlock.

.PARAMETER NoMarker
  Skip creating i_know_what_i_am_doing.txt (then you must press Space each boot).

.EXAMPLE
  .\esp-deploy.ps1 -SourceDir F:\
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [string]$TargetDir = '\EFI\nvunlock',
    [switch]$NoMarker
)

$ErrorActionPreference = 'Stop'

function Get-FreeLetter {
    foreach ($l in @('Z', 'Y', 'X', 'W', 'V', 'U')) {
        if (-not (Test-Path "${l}:\")) { return $l }
    }
    throw 'no free drive letter'
}

$letter = Get-FreeLetter
& mountvol "${letter}:" /S | Out-Null
Start-Sleep -Seconds 2
if (-not (Test-Path "${letter}:\")) { throw 'failed to mount the ESP' }

try {
    $espRoot = "${letter}:\"
    $dst = Join-Path $espRoot $TargetDir
    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    $loader = Join-Path $SourceDir 'BOOTX64.EFI'
    if (-not (Test-Path $loader)) { throw "BOOTX64.EFI not found in $SourceDir" }
    Copy-Item $loader (Join-Path $dst 'BOOTX64.EFI') -Force
    $h = (Get-FileHash (Join-Path $dst 'BOOTX64.EFI') -Algorithm SHA256).Hash
    Write-Host ("loader -> {0}\BOOTX64.EFI  {1} bytes  sha256={2}" -f $TargetDir, (Get-Item $loader).Length, $h)

    $assets = @(
        'booter_load_ad102.bin',
        'gsp_boot_ad102.bin',
        'gsp_boot_desc_ad102.bin',
        'fwimage_ad102.bin',
        'fwsignature_ad102.bin',
        'scrubber_ad10x.bin',
        'v67-ad102-four-plm.bin'
    )
    foreach ($a in $assets) {
        $s = Join-Path $SourceDir $a
        if (-not (Test-Path $s)) { Write-Host "skip $a (absent)"; continue }
        Copy-Item $s (Join-Path $espRoot $a) -Force
        Write-Host ("asset -> \{0}  {1:N0} bytes" -f $a, (Get-Item $s).Length)
    }

    if (-not $NoMarker) {
        $m = Join-Path $espRoot 'i_know_what_i_am_doing.txt'
        if (-not (Test-Path $m)) { New-Item -ItemType File -Path $m | Out-Null }
        Write-Host 'marker i_know_what_i_am_doing.txt present (5 s auto-run)'
    }

    $v = Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -eq "${letter}:" }
    if ($v) { Write-Host ("free on ESP after deploy: {0:N0} MB" -f ($v.FreeSpace / 1MB)) }
}
finally {
    & mountvol "${letter}:" /D | Out-Null
}
