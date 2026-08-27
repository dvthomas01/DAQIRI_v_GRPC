<#
  Slide 13 of Intern_showcase_Dami.pptx: put two charts on it instead of one.

  Why two. The bar chart is a single payload size, and a single payload size
  invites a fair objection: 4 MB could be the one width where the two shared
  memory arms happen to land where they do. The line chart answers that by
  walking all nine sizes. It draws only the two arms that take the same route
  into the GPU, since a difference between those two is a difference in the
  receive path and nothing else.

  Everywhere else in this deck the rule is one chart per slide. This is the
  slide the whole of Part 3 has been building toward, so it earns the exception.

  The slide is found by headline text rather than by index, because the deck has
  been reordered twice and an index would eventually write to the wrong slide.
  Re-running this is safe: it deletes the pictures it owns and redraws them.
#>

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$deckPath = Join-Path $PSScriptRoot "Intern_showcase_Dami.pptx"
$figs = Join-Path $PSScriptRoot "figs"

$pp = $null
try { $pp = [Runtime.InteropServices.Marshal]::GetActiveObject("PowerPoint.Application") } catch { }
if (-not $pp) { $pp = New-Object -ComObject PowerPoint.Application; $pp.Visible = $true }

$deck = $null
foreach ($p in $pp.Presentations) { if ($p.FullName -eq $deckPath) { $deck = $p } }
if (-not $deck) { $deck = $pp.Presentations.Open($deckPath) }

function Get-Shape($slide, $name) {
  foreach ($sh in $slide.Shapes) { if ($sh.Name -eq $name) { return $sh } }
  return $null
}

# Aspect-fit a picture inside a box and centre it there, so the two charts sit
# on a shared baseline even though their tight bounding boxes differ slightly.
# Aspect-fit a picture inside a box and centre it there, so the two charts sit
# on a shared baseline even though their tight bounding boxes differ slightly.
# The size is worked out from the PNG's own pixel dimensions and handed to
# AddPicture as arguments. Setting Shape.Width and Shape.Height afterwards
# throws "specified cast is not valid" from this version of the COM binder.
function Set-Picture($slide, $file, $L, $T, $W, $H, $newName) {
  $img = [System.Drawing.Image]::FromFile($file)
  $px = $img.Width; $py = $img.Height
  $img.Dispose()
  $s = [Math]::Min($W / $px, $H / $py)
  $w2 = [single]($px * $s)
  $h2 = [single]($py * $s)
  $pic = $slide.Shapes.AddPicture($file, 0, -1,
                                  [single]($L + ($W - $w2) / 2),
                                  [single]($T + ($H - $h2) / 2),
                                  $w2, $h2)
  $pic.Name = $newName
  $pic.ZOrder(1) | Out-Null   # msoSendToBack, so text stays on top
  return $pic
}

$target = $null
foreach ($s in $deck.Slides) {
  $h = Get-Shape $s "TextBox 3"
  if ($h -and $h.TextFrame.HasText -eq -1 -and
      $h.TextFrame.TextRange.Text -like "*Where it ended*") { $target = $s }
}
if (-not $target) { throw "no slide with a 'Where it ended' headline" }
"slide {0}: {1}" -f $target.SlideIndex, $target.Shapes.Item("TextBox 3").TextFrame.TextRange.Text

# Clear whatever pictures are on it now, plus the right-hand body text, whose
# column the second chart is taking over. Its content moves to the notes page.
$doomed = @()
foreach ($sh in $target.Shapes) {
  if ($sh.Type -eq 13 -or $sh.Name -eq "TextBox 7") { $doomed += $sh }
}
foreach ($sh in $doomed) { "  removed: " + $sh.Name; $sh.Delete() }

Set-Picture $target (Join-Path $figs "sc_p3_6_final.png") 26 146 445 300 "ChartFinal" | Out-Null
Set-Picture $target (Join-Path $figs "sc_p3_6_sweep.png") 483 146 445 300 "ChartSweep" | Out-Null
"  placed both charts"

$note = Get-Shape $target "Footnote"
if (-not $note) {
  $note = $target.Shapes.AddTextbox(1, 34, 458, 890, 62)
  $note.Name = "Footnote"
}
$note.Left = 34; $note.Top = 456; $note.Width = 890; $note.Height = 66
$note.TextFrame.WordWrap = -1
$note.TextFrame.TextRange.Text = @"
Left: 12 repetitions per bar, whiskers are a 95% confidence interval on the median. Right: a separate nine-size run, 2 repetitions each, which is why its 4 MB points read 70.4 and 62.3 rather than 74.1 and 66.2. Read it for shape.
All four arms run on one machine, so these are receive-side software costs. Time on the wire is not in these numbers.
Open item: across a 200-fold change in data rate the RDMA arm moves 23 microseconds and nothing else moves 2.
"@ -replace "`r`n", "`r"
$tr = $note.TextFrame.TextRange
$tr.Font.Size = 11
$tr.Font.Name = "Segoe UI"
$tr.Font.Color.RGB = 0x706A5A   # SLATE (#5A6470) in BGR
$tr.ParagraphFormat.SpaceWithin = 1.05
"  footnote set"

$deck.Save()
"SAVED: " + $deck.FullName
