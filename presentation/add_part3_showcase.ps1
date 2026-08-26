# Adds Part 3 to Intern_showcase_Dami.pptx, and fixes two things in Parts 1 and 2.
#
# Every new slide is a duplicate of slide 5, so the left accent bar, the kicker
# style, the headline style, the rule and the slide-number placeholder are
# inherited rather than rebuilt. Only the text and the picture are replaced.
#
# Charts come from scripts/make_showcase_figs.py, which reads them out of the
# CSVs at draw time. Run that first.
#
# The script attaches to a running PowerPoint if the deck is already open,
# otherwise it opens the file. It refuses to run twice: Part 3 is only added
# when the deck still has exactly 7 slides.

Add-Type -AssemblyName System.Drawing

$DeckPath = "C:\Users\doluwada\DAQIRI_GPU\presentation\Intern_showcase_Dami.pptx"
$FIG      = "C:\Users\doluwada\DAQIRI_GPU\presentation\figs"
$KICKER   = "PART 3: CLOSING THE GAP"

# --- attach or open -------------------------------------------------------
$app = $null
try { $app = [Runtime.InteropServices.Marshal]::GetActiveObject("PowerPoint.Application") } catch { }
if (-not $app) { $app = New-Object -ComObject PowerPoint.Application }
$deck = $null
foreach ($p in $app.Presentations) { if ($p.FullName -eq $DeckPath) { $deck = $p } }
if (-not $deck) { $deck = $app.Presentations.Open($DeckPath) }
Write-Host "deck: $($deck.Name), slides: $($deck.Slides.Count)"

# --- helpers --------------------------------------------------------------
function Get-Shape($slide, $name) {
    foreach ($sh in $slide.Shapes) { if ($sh.Name -eq $name) { return $sh } }
    return $null
}

function Set-Body($slide, [string[]]$lines, [single]$size = 0) {
    $box = Get-Shape $slide "TextBox 7"
    $box.TextFrame.TextRange.Text = ($lines -join "`r")
    if ($size -gt 0) { $box.TextFrame.TextRange.Font.Size = $size }
    $box.TextFrame.TextRange.Font.Bold = 0
}

function Set-Picture($slide, [string]$file, [single]$boxL, [single]$boxT, [single]$boxW, [single]$boxH) {
    foreach ($sh in @($slide.Shapes)) { if ($sh.Type -eq 13) { $sh.Delete() } }
    $img = [System.Drawing.Image]::FromFile($file)
    $ar = $img.Width / $img.Height
    $img.Dispose()
    $w = $boxW; $h = $w / $ar
    if ($h -gt $boxH) { $h = $boxH; $w = $h * $ar }
    $pic = $slide.Shapes.AddPicture($file, 0, -1,
             $boxL + ($boxW - $w) / 2, $boxT + ($boxH - $h) / 2, $w, $h)
    $pic.ZOrder(1) | Out-Null   # msoSendToBack, keeps it off the text
}

function New-Part3Slide([int]$index, [string]$headline) {
    $dup = $deck.Slides.Item(5).Duplicate()
    $s = $dup.Item(1)
    $s.MoveTo($index)
    (Get-Shape $s "TextBox 2").TextFrame.TextRange.Text = $KICKER
    (Get-Shape $s "TextBox 3").TextFrame.TextRange.Text = $headline
    return $s
}

# =========================================================================
# Slide 2: the agenda showed two parts and the talk has three
# =========================================================================
$s2 = $deck.Slides.Item(2)
$move = @{ "Rectangle 5" = 140; "TextBox 6" = 154; "TextBox 7" = 194;
           "Rectangle 8" = 218; "TextBox 9" = 232; "TextBox 10" = 272;
           "Rectangle 11" = 296; "TextBox 12" = 310; "TextBox 13" = 436 }
foreach ($k in $move.Keys) { (Get-Shape $s2 $k).Top = $move[$k] }
(Get-Shape $s2 "TextBox 13").TextFrame.TextRange.Text =
    "I measured the delay added at each stage, then went after what was left."
$ag = (Get-Shape $s2 "TextBox 4").TextFrame.TextRange
$ag.Text = $ag.Text -replace "the path in two stages", "the path in stages"
if (-not (Get-Shape $s2 "Part3Box")) {
    (Get-Shape $s2 "TextBox 10").Copy()
    $a = $s2.Shapes.Paste().Item(1); $a.Name = "Part3Arrow"
    $a.Left = 560; $a.Top = 350; $a.Width = 340; $a.Height = 17
    (Get-Shape $s2 "Rectangle 11").Copy()
    $r = $s2.Shapes.Paste().Item(1); $r.Name = "Part3Box"
    $r.Left = 560; $r.Top = 374; $r.Width = 340; $r.Height = 52
    (Get-Shape $s2 "TextBox 12").Copy()
    $t = $s2.Shapes.Paste().Item(1); $t.Name = "Part3Label"
    $t.Left = 560; $t.Top = 388; $t.Width = 340; $t.Height = 18
    $t.TextFrame.TextRange.Text = "Part 3: closing the gap"
}
Write-Host "slide 2 updated"

# =========================================================================
# Part 1, slide 5: replace the two-bar chart with the single result
# =========================================================================
$s5 = $deck.Slides.Item(5)
(Get-Shape $s5 "TextBox 3").TextFrame.TextRange.Text =
    "gRPC Direct over RDMA reaches 98% of the 50-gigabit line rate"
Set-Picture $s5 "$FIG\sc_linerate.png" 40 155 520 340
Set-Body $s5 @(
 "This test measures how much data per second crosses the 50-gigabit link. gRPC Direct over RDMA sustains 6.13 gigabytes per second, which is 98 percent of the theoretical maximum.",
 "",
 "That is a throughput result. How fast a single buffer reaches the GPU is a separate question, and Part 2 answers it."
)
Write-Host "slide 5 updated"

# =========================================================================
# Part 2, slide 7: drop the throughput-tie claim, which was withdrawn
# =========================================================================
Set-Body $deck.Slides.Item(7) @(
 "Part 1 measured how much data per second the link carries. This measures something different: how long one buffer takes to get from the wire into the GPU.",
 "",
 "DAQiri came out ahead at every payload size. Throughput and latency are separate questions, and Part 3 is about closing this one."
)
Write-Host "slide 7 updated"

# =========================================================================
# Part 3, inserted after the last Part 2 slide
# =========================================================================
$have3 = $false
foreach ($sl in $deck.Slides) {
    $kb = Get-Shape $sl "TextBox 2"
    if ($kb -and $kb.TextFrame.HasText -eq -1 -and
        $kb.TextFrame.TextRange.Text -eq $KICKER) { $have3 = $true }
}
$P3 = 9   # first Part 3 slide
if ($have3) {
    Write-Host "Part 3 already present; skipping."
} else {

# --- 8: where the delay was ----------------------------------------------
$s = New-Part3Slide $P3 "The delay grew with the size of the buffer, which told me where to look"
Set-Picture $s "$FIG\sc_p3_1_where.png" 34 150 570 320
Set-Body $s @(
 "I subtracted the FFT time from the total, which leaves everything the pipeline does around the math.",
 "DAQiri's stays flat near 5 microseconds from 16 KB all the way to 4 MB. That is a fixed startup cost.",
 "gRPC Direct's climbs from 8 to 82. A cost that grows with the byte count means something is touching every byte.",
 "So the FFT was not the problem. Something was copying the data."
) 15

# --- 9: the cause ---------------------------------------------------------
$s = New-Part3Slide ($P3 + 1) "The cause was an alignment check that could never pass"
Set-Picture $s "$FIG\sc_p3_2_cause.png" 34 150 520 330
Set-Body $s @(
 "The receiver checked whether each incoming buffer was aligned to 16 bytes, and copied it somewhere aligned when it was not.",
 "The library that packs the messages only ever gives 8-byte alignment, so the check failed on every single message.",
 "cuFFT accepts the 8-byte pointer anyway. The fix stops guessing and asks cuFFT directly whether it will take the buffer, so the copy only happens if it is ever really needed.",
 "It hid because the copy is asynchronous. The timer around it read 3.5 microseconds; the real 77 surfaced later, inside the wait for the FFT."
) 15

# --- 10: what was left ----------------------------------------------------
$s = New-Part3Slide ($P3 + 2) "What is left sits inside the FFT library, not in the transport"
Set-Picture $s "$FIG\sc_p3_3_remainder.png" 34 150 570 320
Set-Body $s @(
 "After the fix, gRPC Direct is still a little behind DAQiri. I split that remainder into two parts.",
 "The part outside the FFT library stays under 2 microseconds at every size.",
 "The part inside it grows with the payload, from 0.8 to 6.4 microseconds.",
 "At 4 MB, 79 percent of what is left is inside the FFT library. The transport is no longer the thing to work on."
) 15

# --- 11: the memory result that flipped -----------------------------------
$s = New-Part3Slide ($P3 + 3) "A result I had trusted inverted when I removed one step"
Set-Picture $s "$FIG\sc_p3_4_memory.png" 34 150 560 330
Set-Body $s @(
 "The GPU can read host memory two ways: let CUDA allocate the pages, or hand it pages the program already owns.",
 "Ours measured slower every way I tried it, by 7 to 11 microseconds. That is the result that started the RDMA work.",
 "Then I removed the CPU write that had been filling the buffer, and the sign flipped. Ours came out 11 microseconds faster.",
 "Both measurements were right about what they measured. The mistake available was carrying one into a setup it had never measured, and that setup is the one that ships: a network card fills the buffer and no CPU touches it."
) 13

# --- 12: what got built (diagram, no chart) -------------------------------
$s = New-Part3Slide ($P3 + 4) "What I built: the card writes into memory the GPU reads"
foreach ($sh in @($s.Shapes)) { if ($sh.Type -eq 13) { $sh.Delete() } }
Set-Body $s @(
 "The instrument chassis has no NVIDIA GPU and cannot run CUDA. DAQiri needs CUDA on both ends, so it cannot make this trip at all.",
 "One allocation is registered twice, once with the network card and once with CUDA. Both of them address the same bytes.",
 "The card writes into it directly. The FFT reads it in place. There is no staging copy anywhere on this path.",
 "This is the path that runs at 98 percent of line rate in Part 1."
) 14
$src = $deck.Slides.Item(2)
$boxT = 158, 244, 330, 416
$boxTxt = @(
 "Instrument chassis  (no GPU, no CUDA)",
 "50 Gb/s RDMA link",
 "One host buffer, registered with the card and with CUDA",
 "The FFT reads it where it landed")
for ($i = 0; $i -lt 4; $i++) {
    # box 2 is the one the whole slide is about, so it gets the accent fill
    (Get-Shape $src $(if ($i -eq 2) { "Rectangle 8" } else { "Rectangle 5" })).Copy()
    $r = $s.Shapes.Paste().Item(1); $r.Name = "DiagBox$i"
    $r.Left = 40; $r.Top = $boxT[$i]; $r.Width = 500; $r.Height = 52
    (Get-Shape $src "TextBox 6").Copy()
    $t = $s.Shapes.Paste().Item(1); $t.Name = "DiagLabel$i"
    $t.Left = 40; $t.Top = $boxT[$i] + 14; $t.Width = 500; $t.Height = 24
    $t.TextFrame.TextRange.Text = $boxTxt[$i]
    if ($i -lt 3) {
        (Get-Shape $src "TextBox 7").Copy()   # already contains the arrow glyph
        $a = $s.Shapes.Paste().Item(1); $a.Name = "DiagArrow$i"
        $a.Left = 40; $a.Top = $boxT[$i] + 54; $a.Width = 500; $a.Height = 17
    }
}

# --- 13: where it ended ---------------------------------------------------
$s = New-Part3Slide ($P3 + 5) "Where it ended: 1.71 times faster, and 7 microseconds behind DAQiri"
Set-Picture $s "$FIG\sc_p3_6_final.png" 34 150 570 320
Set-Body $s @(
 "Twelve repetitions per bar, with each transport rotated through all four running positions so that no one of them gets the best slot.",
 "The whiskers show what the measurement can actually resolve. gRPC Direct is 6.96 microseconds behind DAQiri, in 12 repetitions out of 12.",
 "I ran the whole test again at an eighth of the data rate and got 7.02. That answer does not depend on how hard the link is driven.",
 "The RDMA path is the exception. It moves 23 microseconds between those two rates, and that is the open question I am handing on."
) 14

Write-Host "Part 3 added: slides $P3 to $($P3 + 5)"
}

# =========================================================================
# Closing slides: the network-throughput tie was withdrawn, and Part 3
# changed what the next steps are
# =========================================================================
foreach ($sl in $deck.Slides) {
    $t2 = Get-Shape $sl "TextBox 2"
    if (-not $t2 -or $t2.TextFrame.HasText -ne -1) { continue }
    $head = $t2.TextFrame.TextRange.Text
    $b = Get-Shape $sl "TextBox 4"
    if (-not $b) { continue }
    if ($head -like "The bottom line*") {
        $b.TextFrame.TextRange.Text = @(
         "Up to 281 times lower latency and about four times the throughput, with no change to application code",
         "gRPC Direct over RDMA carries 98 percent of the 50-gigabit line rate, from an instrument chassis that has no GPU in it",
         "In the GPU pipeline, gRPC Direct is now 1.71 times faster than it was and sits about 7 microseconds behind DAQiri",
         "That headroom makes tighter control loops and faster inference practical, and widens the hardware we can support"
        ) -join "`r"
    }
    if ($head -like "Next Steps*") {
        $b.TextFrame.TextRange.Text = @(
         "Find out why the RDMA path loses 23 microseconds when the link is driven harder, which is the one arm that reacts to offered rate",
         "Take the remaining gap to the FFT library itself, since 79 percent of what is left is inside it",
         "Confirm the results on the main network to GPU path using real hardware data",
         "Write up the findings as a transport recommendation other NI teams can use"
        ) -join "`r"
    }
}
Write-Host "closing slides updated"

$deck.Save()
Write-Host "SAVED: $($deck.FullName)  ($($deck.Slides.Count) slides)"
