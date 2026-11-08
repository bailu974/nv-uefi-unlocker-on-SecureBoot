#requires -RunAsAdministrator
<#
.SYNOPSIS
  Restore Boot0000 (and optionally the fallback slot) from the raw dumps written
  by set-boot-entry.ps1.

.EXAMPLE
  .\rollback-boot-entry.ps1
  .\rollback-boot-entry.ps1 -BackupDir D:\nv-unlock\backup -AlsoRestore Boot2001
#>
[CmdletBinding()]
param(
    [string]$BackupDir = "$env:ProgramData\nv-unlock\backup",
    [string]$AlsoRestore = ''
)

$ErrorActionPreference = 'Stop'

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class FwVarRb
{
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buf, uint size, uint attrs);
    public static int LastError;
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
if (-not [FwVarRb]::EnablePrivilege('SeSystemEnvironmentPrivilege')) { throw 'need elevation' }

$G = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'
$ATTRS = 0x07

function Restore-Var([string]$name) {
    $p = Join-Path $BackupDir ($name + '.orig.bin')
    if (-not (Test-Path $p)) { Write-Host "skip $name (no $p)"; return }
    $b = [byte[]]([IO.File]::ReadAllBytes($p))
    $ok = [FwVarRb]::Write($name, $G, $b, $ATTRS)
    Write-Host ("restore {0,-10} <- {1} bytes -> {2} err={3}" -f $name, $b.Length, $ok, [FwVarRb]::LastError)
}

Restore-Var 'Boot0000'
if ($AlsoRestore) { Restore-Var $AlsoRestore }
Write-Host 'done - reboot to confirm'
