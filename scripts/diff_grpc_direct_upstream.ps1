# Compare the PXI's grpc-direct working copy against upstream ni/grpc-direct.
#
# The PXI copy has no .git, so provenance has to be established by content.
# Writes a three-way classification: identical, MODIFIED, PXI-only, upstream-only.

param(
  [string]$Upstream = "$env:USERPROFILE\_scratch\grpc-direct-upstream",
  [string]$PxiHashes = "data\gd_hashes_pxi.txt"
)

$ErrorActionPreference = "Stop"

# --- read the PXI side: "<md5>  ./path" ---
$pxi = @{}
foreach ($line in Get-Content $PxiHashes) {
  if ($line -match '^([0-9a-f]{32})\s+\.?/?(.+)$') {
    $pxi[$Matches[2] -replace '\\','/'] = $Matches[1]
  }
}

# --- hash the upstream side, same exclusions ---
$up = @{}
Push-Location $Upstream
$files = git ls-files
Pop-Location
foreach ($f in $files) {
  if ($f -like '.github/*') { continue }
  $full = Join-Path $Upstream $f
  if (-not (Test-Path $full)) { continue }
  $up[$f] = (Get-FileHash -Algorithm MD5 $full).Hash.ToLower()
}

$same = @(); $diff = @(); $pxiOnly = @(); $upOnly = @()

foreach ($k in $pxi.Keys) {
  if ($up.ContainsKey($k)) {
    if ($up[$k] -eq $pxi[$k]) { $same += $k } else { $diff += $k }
  } else { $pxiOnly += $k }
}
foreach ($k in $up.Keys) { if (-not $pxi.ContainsKey($k)) { $upOnly += $k } }

"=== summary ==="
"  identical      : {0}" -f $same.Count
"  MODIFIED       : {0}" -f $diff.Count
"  PXI-only       : {0}" -f $pxiOnly.Count
"  upstream-only  : {0}" -f $upOnly.Count
""
"=== MODIFIED (content differs from upstream HEAD) ==="
$diff | Sort-Object | ForEach-Object { "  $_" }
""
"=== PXI-only (not in upstream) ==="
$pxiOnly | Sort-Object | ForEach-Object { "  $_" }
""
"=== upstream-only (missing on the PXI) ==="
$upOnly | Sort-Object | ForEach-Object { "  $_" }
