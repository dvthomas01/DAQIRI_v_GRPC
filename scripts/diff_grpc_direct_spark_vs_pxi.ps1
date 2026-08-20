# Compare the Spark's grpc-direct working copy against the PXI's.
#
# Both are the same upstream base (2d404a5). The question is whether the code
# that would run under a Spark-built RDMA number is the code the PXI audit
# actually looked at.

param(
  [string]$SparkHashes = "data\gd_hashes_spark.txt",
  [string]$PxiHashes   = "data\gd_hashes_pxi.txt"
)

$ErrorActionPreference = "Stop"

function Read-Hashes($path) {
  $h = @{}
  foreach ($line in Get-Content $path) {
    if ($line -match '^([0-9a-f]{32})\s+\.?/?(.+)$') {
      $h[($Matches[2] -replace '\\','/')] = $Matches[1]
    }
  }
  return $h
}

$spark = Read-Hashes $SparkHashes
$pxi   = Read-Hashes $PxiHashes

# The Spark copy keeps its .git; the PXI copy does not. Comparing them would
# report the whole object store as a difference, which is not a finding.
$sparkKeys = $spark.Keys | Where-Object { $_ -notlike '.git/*' }

$same = @(); $diff = @(); $sparkOnly = @(); $pxiOnly = @()

foreach ($k in $sparkKeys) {
  if ($pxi.ContainsKey($k)) {
    if ($pxi[$k] -eq $spark[$k]) { $same += $k } else { $diff += $k }
  } else { $sparkOnly += $k }
}
foreach ($k in $pxi.Keys) { if (-not $spark.ContainsKey($k)) { $pxiOnly += $k } }

"identical      : {0}" -f $same.Count
"DIFFERENT      : {0}" -f $diff.Count
$diff | Sort-Object | ForEach-Object { "    ~ $_" }
"Spark-only     : {0}" -f $sparkOnly.Count
$sparkOnly | Sort-Object | ForEach-Object { "    + $_" }
"PXI-only       : {0}" -f $pxiOnly.Count
$pxiOnly | Sort-Object | ForEach-Object { "    - $_" }
