# Discover NI Real-Time systems (PXIs) on the network via the NI System Configuration API.
# Uses nisyscfg.dll (installed in C:\Windows\System32). Lists IP + hostname of every
# reachable NI-RT target so we can identify which PXIe-8881 is which.

$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class NiSysCfg
{
    // NISysCfgFindSystems: sessionHandle=NULL for network-wide discovery.
    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int NISysCfgFindSystems(
        IntPtr sessionHandle,
        string deviceClass,
        int detectOnlineSystems,        // NISysCfgBool: 1 = True
        int cacheMode,                  // NISysCfgIncludeCachedResultsAll = 3
        int findOutputMode,             // NISysCfgSystemNameFormatIpHostname = 0x21
        double timeoutMsec,
        int onlyInstallableSystems,     // NISysCfgBool: 0 = False
        out IntPtr enumHandle);

    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int NISysCfgNextSystemInfo(IntPtr enumHandle, StringBuilder systemName);

    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int NISysCfgCloseHandle(IntPtr handle);
}
'@

try {
    Add-Type -TypeDefinition $sig -ErrorAction Stop
} catch {
    Write-Host "Failed to bind nisyscfg.dll: $($_.Exception.Message)"
    exit 1
}

$enum = [IntPtr]::Zero
# deviceClass null = all; detectOnline=1; cache=3 (all); outputMode=0x21 (IP + Hostname); 8s timeout
$status = [NiSysCfg]::NISysCfgFindSystems([IntPtr]::Zero, $null, 1, 3, 0x21, 8000, 0, [ref]$enum)

if ($status -ne 0) {
    Write-Host "NISysCfgFindSystems returned status $status (non-zero). No enumeration."
    exit 1
}

Write-Host "=== NI Real-Time systems found on the network ==="
$count = 0
$sb = New-Object System.Text.StringBuilder 1024
while ([NiSysCfg]::NISysCfgNextSystemInfo($enum, $sb) -eq 0) {
    $count++
    "{0,3}. {1}" -f $count, $sb.ToString()
    $sb = New-Object System.Text.StringBuilder 1024
}
if ($count -eq 0) { Write-Host "(none returned)" }
Write-Host "=== total: $count ==="

[void][NiSysCfg]::NISysCfgCloseHandle($enum)
