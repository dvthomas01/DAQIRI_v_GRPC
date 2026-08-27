# Query a specific NI target by IP via the NI System Configuration API (nisyscfg.dll)
# to retrieve product name, serial number, OS, and MAC. Works over unicast port 3580
# (network find via mDNS is blocked across subnets, but direct session init works).

param([string]$Target = "10.198.65.114", [string]$User = "", [string]$Pass = "")

$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class NiCfg
{
    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int NISysCfgInitializeSession(
        string targetName, string username, string password,
        int language, int forcePropertyRefresh, uint connectTimeoutMsec,
        IntPtr expertEnumHandle, out IntPtr sessionHandle);

    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int NISysCfgGetSystemProperty(IntPtr sessionHandle, int propertyID, StringBuilder value);

    [DllImport("nisyscfg.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int NISysCfgCloseHandle(IntPtr handle);
}
'@
Add-Type -TypeDefinition $sig -ErrorAction Stop

# NISysCfgSystemProperty string IDs (base 0x01029000 = 16941056)
$props = [ordered]@{
    "DeviceClass"     = 16941056
    "FirmwareRev"     = 16941059
    "MacAddress"      = 16941066
    "ProductName"     = 16941067
    "OperatingSystem" = 16941068
    "SerialNumber"    = 16941069
}

$sess = [IntPtr]::Zero
Write-Host "Connecting to $Target on port 3580 (user='$User') ..."
$u = if ([string]::IsNullOrEmpty($User)) { $null } else { $User }
$p = if ([string]::IsNullOrEmpty($Pass)) { $null } else { $Pass }
$st = [NiCfg]::NISysCfgInitializeSession($Target, $u, $p, 0, 1, 10000, [IntPtr]::Zero, [ref]$sess)
if ($st -ne 0) {
    Write-Host "NISysCfgInitializeSession failed, status=$st"
    exit 1
}
Write-Host "Session opened. Reading properties:"
foreach ($name in $props.Keys) {
    $sb = New-Object System.Text.StringBuilder 1024
    $r = [NiCfg]::NISysCfgGetSystemProperty($sess, $props[$name], $sb)
    if ($r -eq 0) { "{0,-16}: {1}" -f $name, $sb.ToString() }
    else          { "{0,-16}: (status $r)" -f $name }
}
[void][NiCfg]::NISysCfgCloseHandle($sess)
