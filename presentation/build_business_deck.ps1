# =====================================================================
# BUSINESS / IMPACT DECK
# Structure : Assertion-Evidence (AE)  +  10/20/30 delivery rule
#   - <= 10 content slides, >= 30pt headline font, one visual per slide
#   - Each slide TITLE is a full-sentence assertion; the chart is the evidence
# Palette   : National Instruments (NI)
# Build     : PowerPoint COM automation
# =====================================================================
$ErrorActionPreference = 'Stop'

function RGB($r,$g,$b){ return [int]($r + $g*256 + $b*65536) }
$NIGreen  = RGB 3   181 133   # #03B585
$Charcoal = RGB 27  27  27    # #1B1B1B
$Slate    = RGB 90  100 112   # #5A6470
$OffWhite = RGB 247 248 249   # #F7F8F9
$Amber    = RGB 245 166 35    # #F5A623
$White    = RGB 255 255 255
$LightGrn = RGB 224 245 238

$msoHoriz=1; $blank=12; $rect=1; $msoTrue=-1; $msoFalse=0
$alignLeft=1; $alignCenter=2; $alignRight=3
$W=960; $H=540; $FONT='Segoe UI'

$FIG = "C:\Users\doluwada\DAQIRI_GPU\presentation\figs"
$OUT = "C:\Users\doluwada\DAQIRI_GPU\presentation\NI_business_impact_deck.pptx"

$ppt = New-Object -ComObject PowerPoint.Application
$pres = $ppt.Presentations.Add($msoFalse)
$pres.PageSetup.SlideSize = 15
$pres.PageSetup.SlideWidth = $W
$pres.PageSetup.SlideHeight = $H

function New-Blank {
    $s = $pres.Slides.Add($pres.Slides.Count+1, $blank)
    $s.FollowMasterBackground = $msoFalse
    $s.Background.Fill.Solid()
    $s.Background.Fill.ForeColor.RGB = $OffWhite
    return $s
}
function Add-Rect($s,$l,$t,$w,$h,$color){
    $sh = $s.Shapes.AddShape($rect,$l,$t,$w,$h)
    $sh.Fill.Solid(); $sh.Fill.ForeColor.RGB = $color
    $sh.Line.Visible = $msoFalse
    return $sh
}
function Add-Text($s,$l,$t,$w,$h,$text,$size,$bold,$color,$align){
    $tb = $s.Shapes.AddTextbox($msoHoriz,$l,$t,$w,$h)
    $tf = $tb.TextFrame; $tf.WordWrap = $msoTrue
    $tf.MarginLeft=0; $tf.MarginRight=0; $tf.MarginTop=0; $tf.MarginBottom=0
    $tr = $tf.TextRange
    $tr.Text = $text
    $tr.Font.Name = $FONT; $tr.Font.Size = $size
    $tr.Font.Bold = $(if($bold){$msoTrue}else{$msoFalse})
    $tr.Font.Color.RGB = $color
    $tr.ParagraphFormat.Alignment = $align
    return $tb
}
# AE assertion header: full-sentence takeaway across the top, with an optional
# part-marker kicker to thread the deck together
function Add-Assertion($s,$title,$kicker){
    Add-Rect $s 0 0 10 $H $NIGreen | Out-Null
    if($kicker){
        Add-Text $s 54 26 850 20 $kicker 12 $true $NIGreen $alignLeft | Out-Null
        Add-Text $s 54 46 850 88 $title 25 $true $Charcoal $alignLeft | Out-Null
        Add-Rect $s 56 132 70 5 $NIGreen | Out-Null
    } else {
        Add-Text $s 54 30 850 96 $title 27 $true $Charcoal $alignLeft | Out-Null
        Add-Rect $s 56 128 70 5 $NIGreen | Out-Null
    }
}
function Add-Footnote($s,$text){
    Add-Text $s 54 516 850 18 $text 10 $false $Slate $alignLeft | Out-Null
}
function Add-Picture($s,$file,$boxL,$boxT,$boxW,$boxH){
    $pic = $s.Shapes.AddPicture($file,$msoFalse,$msoTrue,$boxL,$boxT,-1,-1)
    $pic.LockAspectRatio = $msoTrue
    $scale = [Math]::Min($boxW/$pic.Width, $boxH/$pic.Height)
    $pic.Width = $pic.Width * $scale
    $pic.Left = $boxL + ($boxW - $pic.Width)/2
    $pic.Top  = $boxT + ($boxH - $pic.Height)/2
    return $pic
}
function Add-Bullets($s,$l,$t,$w,$h,$items,$size){
    $tb = $s.Shapes.AddTextbox($msoHoriz,$l,$t,$w,$h)
    $tf = $tb.TextFrame; $tf.WordWrap=$msoTrue
    $tf.MarginLeft=0; $tf.MarginRight=0; $tf.MarginTop=0; $tf.MarginBottom=0
    $tr = $tf.TextRange
    $tr.Text = ($items -join "`r")
    $tr.Font.Name=$FONT; $tr.Font.Size=$size; $tr.Font.Color.RGB=$Charcoal
    $tr.ParagraphFormat.Alignment=$alignLeft
    $tr.ParagraphFormat.Bullet.Visible=$msoTrue
    $tr.ParagraphFormat.Bullet.Character=8226
    $tr.ParagraphFormat.Bullet.Font.Color.RGB=$NIGreen
    $tr.ParagraphFormat.SpaceAfter=18
    return $tb
}

# =====================================================================
# SLIDE 1 - Title
# =====================================================================
$s = New-Blank
Add-Rect $s 0 0 $W $H $Charcoal | Out-Null
Add-Rect $s 0 0 12 $H $NIGreen | Out-Null
Add-Text $s 70 175 800 150 "Getting Live Hardware Data`r to the GPU, Faster" 44 $true $White $alignLeft | Out-Null
Add-Text $s 74 320 800 40 "Comparing the transports that carry live measurements into GPU compute" 19 $false $NIGreen $alignLeft | Out-Null
Add-Text $s 74 474 800 24 "Dami Thomas  |  NI Summer 2026  |  2026-07-29" 13 $false $Slate $alignLeft | Out-Null

# =====================================================================
# SLIDE 2 - Problem + two-part setup (threads the whole deck)
# =====================================================================
$s = New-Blank
Add-Assertion $s "The data path, not the math, is what slows real-time GPU work"
Add-Bullets $s 54 160 470 320 @(
 "Instruments send data without pause, and it has to reach the GPU in microseconds",
 "The usual network path adds delay from the operating system and from copying data in memory",
 "That delay, not the FFT math, is what usually holds real-time work back",
 "So we measured the path in two stages, then compared transports at each stage") 20 | Out-Null
# right-side pipeline diagram (sets up Part 1 / Part 2)
Add-Rect $s 560 158 340 52 $Slate | Out-Null
Add-Text $s 560 172 340 24 "Live instrument data" 15 $true $White $alignCenter | Out-Null
Add-Text $s 560 212 340 20 ([string][char]0x25BC) 14 $true $Slate $alignCenter | Out-Null
Add-Rect $s 560 236 340 52 $NIGreen | Out-Null
Add-Text $s 560 250 340 24 "Part 1: across the network" 15 $true $White $alignCenter | Out-Null
Add-Text $s 560 290 340 20 ([string][char]0x25BC) 14 $true $Slate $alignCenter | Out-Null
Add-Rect $s 560 314 340 52 $NIGreen | Out-Null
Add-Text $s 560 328 340 24 "Part 2: into the GPU (FFT)" 15 $true $White $alignCenter | Out-Null
Add-Text $s 560 376 340 30 "We measured the delay added at each stage." 13 $false $Slate $alignCenter | Out-Null
Add-Footnote $s "Same application code throughout; only the transport underneath changes."

# =====================================================================
# SLIDE 3 - Part 1, 281x latency
# =====================================================================
$s = New-Blank
Add-Assertion $s "Keeping the same code but swapping the transport cut latency up to 281 times" "PART 1: ACROSS THE NETWORK"
Add-Picture $s "$FIG\p1_latency.png" 40 150 570 350 | Out-Null
Add-Text $s 630 165 300 320 "When both sides run on the same machine, shared memory passes the data straight across and skips the operating system's copies. A round trip takes 3.3 microseconds. That is within half a microsecond of the machine's physical limit, and about 281 times faster than standard gRPC.`r`rWhen the data has to reach a second machine, RDMA handles that instead. We put it head to head with NVIDIA on the next slides." 16 $false $Charcoal $alignLeft | Out-Null
Add-Footnote $s "Same-host (localhost) echo round-trip, median p50. Dotted line is the machine's floor (2.78 microseconds); standard gRPC over loopback TCP sits near 1,000."

# =====================================================================
# SLIDE 4 - Part 1, throughput
# =====================================================================
$s = New-Blank
Add-Assertion $s "Skipping the memory copies gave almost four times the streaming throughput" "PART 1: ACROSS THE NETWORK"
Add-Picture $s "$FIG\p1_throughput.png" 250 155 460 345 | Out-Null
Add-Footnote $s "Same-host streaming throughput. Zero-copy writes straight into shared memory instead of copying it twice."

# =====================================================================
# SLIDE 5 - Part 1, RDMA throughput vs NVIDIA (clarified: throughput test)
# =====================================================================
$s = New-Blank
Add-Assertion $s "Our transport runs the network link at 98 percent of its rated speed" "PART 1: ACROSS THE NETWORK"
Add-Picture $s "$FIG\p1_rdma_linerate.png" 40 150 520 350 | Out-Null
Add-Text $s 590 165 335 320 "This test measures how much data per second crosses the 50-gigabit link.`r`rOur first measurement came in at 5.8 gigabytes per second and we read it as the limit of the hardware. It was not. The network was configured with an undersized packet size. Once corrected, the same link carried 6.13 gigabytes per second, which is 98 percent of what a 50-gigabit link can theoretically deliver.`r`rThere is almost nothing left to win on the wire. Everything that remains is in what happens after the data arrives, which is Part 2." 15 $false $Charcoal $alignLeft | Out-Null
Add-Footnote $s "Raw network throughput between two machines, 4 MB transfers. This is not the GPU latency test. An earlier version of this slide compared us against NVIDIA here; that comparison measured the misconfigured network on both sides and has been withdrawn."

# =====================================================================
# SLIDE 6 - Part 2, CPU copy removed
# =====================================================================
$s = New-Blank
Add-Assertion $s "In the GPU pipeline, both transports now skip the big CPU copy" "PART 2: INTO THE GPU"
Add-Picture $s "$FIG\p2_copy_penalty.png" 120 155 720 345 | Out-Null
Add-Footnote $s "One small copy still happens on the GPU. The large copy on the CPU side is gone."

# =====================================================================
# SLIDE 7 - Part 2, DAQiri lower latency + tie-back to slide 5
# =====================================================================
$s = New-Blank
Add-Assertion $s "Getting a buffer into the GPU, DAQiri was faster at every size we tested" "PART 2: INTO THE GPU"
Add-Picture $s "$FIG\p2_zerocopy_latency.png" 40 150 570 350 | Out-Null
Add-Text $s 630 165 300 320 "The two transports tied on raw throughput in Part 1. For the time one buffer takes to reach the GPU, DAQiri came out ahead at every payload.`r`rThroughput and latency are separate questions, and here they point different ways." 16 $false $Charcoal $alignLeft | Out-Null
Add-Footnote $s "End-to-end latency per buffer (p50), both pipelines paced the same for a fair test."

# =====================================================================
# SLIDE 8 - Part 2, open item
# =====================================================================
$s = New-Blank
Add-Assertion $s "One open item: at the largest payload, DAQiri delivered fewer messages" "PART 2: INTO THE GPU"
Add-Picture $s "$FIG\p2_delivery.png" 40 150 600 350 | Out-Null
Add-Text $s 660 190 265 260 "The messages that did arrive were still fast. We are checking whether this is a limit of the test link or a setting we can change." 16 $false $Slate $alignLeft | Out-Null
Add-Footnote $s "Under investigation. It does not change the latency results above."

# =====================================================================
# SLIDE 9 - Impact
# =====================================================================
$s = New-Blank
Add-Assertion $s "The bottom line: moving data faster lets the GPU act in real time"
Add-Bullets $s 54 170 850 300 @(
 "Up to 281 times lower latency and about four times the throughput, with no change to application code",
 "A software transport that keeps pace with dedicated acquisition hardware on the network",
 "A GPU pipeline that reaches the accelerator in tens of microseconds instead of hundreds",
 "That headroom makes tighter control loops and faster inference practical, and widens the hardware we can support") 21 | Out-Null

# =====================================================================
# SLIDE 10 - Next steps
# =====================================================================
$s = New-Blank
Add-Assertion $s "Next: close the open item, then test on production-style hardware"
Add-Bullets $s 54 170 850 300 @(
 "Find what causes the large-payload delivery limit and run the test again",
 "Confirm the results on the main network-to-GPU path once the test system is back online",
 "Write up the findings as a transport recommendation other NI teams can use") 21 | Out-Null
Add-Text $s 54 470 850 30 "Thanks. Happy to take questions." 18 $true $NIGreen $alignLeft | Out-Null

# ---- save ----
$pres.SaveAs($OUT, 24)
$pres.Close()
$ppt.Quit()
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($ppt) | Out-Null
Write-Output "SAVED: $OUT"
