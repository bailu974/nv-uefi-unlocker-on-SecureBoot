#requires -RunAsAdministrator
<#
.SYNOPSIS
  Point the existing Boot0000 (Windows Boot Manager) at a custom EFI application,
  keeping the original device path. The application is expected to chain back to
  \EFI\Microsoft\Boot\bootmgfw.efi itself (nv-uefi-unlocker does).

.DESCRIPTION
  Some laptop firmwares refuse to CREATE new BootXXXX variables
  (SetFirmwareEnvironmentVariableEx -> err 87) while still allowing existing ones
  to be rewritten. This script works around that by editing Boot0000 in place.

  Before writing it:
    * backs up BootOrder and every existing BootXXXX into -BackupDir
    * clones the pristine Windows entry into a free *existing* slot as a fallback
    * only then rewrites Boot0000

  Roll back with rollback-boot-entry.ps1.

.PARAMETER LoaderPath
  Device-path file path of the EFI application, e.g. \EFI\nvunlock\BOOTX64.EFI

.PARAMETER FallbackSlot
  Existing BootXXXX to clone the Windows entry into, e.g. Boot2001.

.PARAMETER BackupDir
  Where the raw variable dumps go.

.EXAMPLE
  .\set-boot-entry.ps1 -LoaderPath '\EFI\nvunlock\BOOTX64.EFI' -FallbackSlot Boot2001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LoaderPath,
    [string]$FallbackSlot = 'Boot2001',
    [string]$BackupDir = "$env:ProgramData\nv-unlock\backup",
    [switch]$SkipFallback
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class FwVarEd
{
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern uint GetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buf, uint size, out uint attrs);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buf, uint size, uint attrs);
    public static uint LastAttrs; public static int LastError;
    public static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return false;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = 0x2;
        return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
    public static byte[] Read(string name, string guid)
    {
        LastAttrs = 0; LastError = 0;
        uint size = 65536; byte[] buf = new byte[size];
        uint got = GetFirmwareEnvironmentVariableEx(name, guid, buf, size, out LastAttrs);
        if (got == 0) { LastError = Marshal.GetLastWin32Error(); return null; }
        byte[] res = new byte[got]; Array.Copy(buf, res, got); return res;
    }
    public static bool Write(string name, string guid, byte[] data, uint attrs)
    {
        LastError = 0;
        bool ok = SetFirmwareEnvironmentVariableEx(name, guid, data, (uint)data.Length, attrs);
        if (!ok) LastError = Marshal.GetLastWin32Error();
        return ok;
    }
}
'@
Add-Type -TypeDefinition $cs | Out-Null
if (-not [FwVarEd]::EnablePrivilege('SeSystemEnvironmentPrivilege')) {
    throw 'cannot enable SeSystemEnvironmentPrivilege (run elevated)'
}

$G = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'
$ATTRS = 0x07

function Get-EntryPath([byte[]]$blob) {
    $p = [BitConverter]::ToUInt16($blob, 4)
    $j = 6
    while ($j + 1 -lt $blob.Length -and -not ($blob[$j] -eq 0 -and $blob[$j+1] -eq 0)) { $j += 2 }
    $pos = $j + 2
    $fin = $pos + $p
    while ($pos -lt $fin) {
        $t = $blob[$pos]; $s = $blob[$pos+1]; $l = [int]$blob[$pos+2] + ([int]$blob[$pos+3] -shl 8)
        if ($t -eq 4 -and $s -eq 4) {
            return [Text.Encoding]::Unicode.GetString($blob, $pos + 4, $l - 4).TrimEnd([char]0)
        }
        $pos += $l
    }
    return $null
}

Write-Host '== backup =='
$order = [FwVarEd]::Read('BootOrder', $G)
if ($null -eq $order) { throw 'cannot read BootOrder' }
[IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.orig.bin'), $order)
$orderNames = @()
for ($i = 0; $i -lt $order.Length; $i += 2) { $orderNames += ('Boot{0:x4}' -f ([int]$order[$i] + ([int]$order[$i+1] -shl 8))) }
Write-Host ('BootOrder: ' + ($orderNames -join ' '))

$orig = [FwVarEd]::Read('Boot0000', $G)
if ($null -eq $orig) { throw 'cannot read Boot0000' }
$orig = [byte[]]$orig
[IO.File]::WriteAllBytes((Join-Path $BackupDir 'Boot0000.orig.bin'), $orig)
Write-Host ('Boot0000: ' + $orig.Length + ' bytes, path=' + (Get-EntryPath $orig))

if (-not $SkipFallback) {
    $fb = [FwVarEd]::Read($FallbackSlot, $G)
    if ($null -eq $fb) { Write-Host "WARN: $FallbackSlot does not exist, skipping fallback" }
    else {
        [IO.File]::WriteAllBytes((Join-Path $BackupDir ($FallbackSlot + '.orig.bin')), $fb)
        $ok = [FwVarEd]::Write($FallbackSlot, $G, $orig, $ATTRS)
        Write-Host ("fallback: $FallbackSlot <- Windows entry -> $ok err=" + [FwVarEd]::LastError)
    }
}

Write-Host '== rewrite Boot0000 =='
$pathLen = [BitConverter]::ToUInt16($orig, 4)
$i = 6
while ($i + 1 -lt $orig.Length -and -not ($orig[$i] -eq 0 -and $orig[$i+1] -eq 0)) { $i += 2 }
$descLen = $i + 2 - 6
$desc = [byte[]]$orig[6..(6 + $descLen - 1)]
$dpStart = 6 + $descLen
$hd = [byte[]]$orig[$dpStart..($dpStart + 41)]                # keep HD() node untouched
$optional = [byte[]]$orig[($dpStart + $pathLen)..($orig.Length - 1)]

$pbytes = [Text.Encoding]::Unicode.GetBytes($LoaderPath + [char]0)
$fpLen = 4 + $pbytes.Length
$fp = New-Object byte[] $fpLen
$fp[0] = 0x04; $fp[1] = 0x04; $fp[2] = [byte]($fpLen -band 0xFF); $fp[3] = [byte](($fpLen -shr 8) -band 0xFF)
[Array]::Copy($pbytes, 0, $fp, 4, $pbytes.Length)
$endNode = [byte[]]@(0x7F, 0xFF, 0x04, 0x00)

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint32]0x00000001)
$lenPos = $ms.Position
$bw.Write([uint16]0)
$bw.Write($desc)
$dpPos = $ms.Position
$bw.Write($hd); $bw.Write($fp); $bw.Write($endNode)
$dpLen = [int]($ms.Position - $dpPos)
$bw.Write($optional)
$bw.Flush()
$payload = [byte[]]$ms.ToArray()
$bw.Dispose(); $ms.Dispose()
[Array]::Copy([BitConverter]::GetBytes([uint16]$dpLen), 0, $payload, $lenPos, 2)

Write-Host ('payload: ' + $payload.Length + ' bytes, pathLen=' + $dpLen)
[IO.File]::WriteAllBytes((Join-Path $BackupDir 'Boot0000.new.bin'), $payload)

$ok = [FwVarEd]::Write('Boot0000', $G, $payload, $ATTRS)
Write-Host ("write Boot0000 -> $ok err=" + [FwVarEd]::LastError)
if (-not $ok) { throw 'firmware refused the write; Boot0000 unchanged' }

$rb = [FwVarEd]::Read('Boot0000', $G)
Write-Host ('readback path = ' + (Get-EntryPath $rb))
Write-Host 'DONE - reboot to test. If it does not boot, use rollback-boot-entry.ps1 from a recovery environment or reset boot order in BIOS.'
