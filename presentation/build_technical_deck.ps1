# =====================================================================
# TECHNICAL REVIEW DECK
# Structure : IEEE Engineering Presentation Architecture
#             + MIL-STD / NASA Technical Review Standard
#   Sections: Objectives & Success Criteria -> Background -> Architecture
#             -> Test Configuration -> Methodology -> Results
#             -> Open-Issue Analysis -> Risk/Limitations
#             -> Conclusions & Verification Status -> Actions -> Backup
# Palette   : National Instruments (NI)
# =====================================================================
$ErrorActionPreference = 'Stop'

function RGB($r,$g,$b){ return [int]($r + $g*256 + $b*65536) }
$NIGreen  = RGB 3   181 133
$NIGrnD   = RGB 2   140 102
$Charcoal = RGB 27  27  27
$Slate    = RGB 90  100 112
$OffWhite = RGB 247 248 249
$Amber    = RGB 245 166 35
$White    = RGB 255 255 255
$LightGrn = RGB 224 245 238
$LightAmb = RGB 252 240 220
$RedT     = RGB 246 224 224

$msoHoriz=1; $blank=12; $rect=1; $msoTrue=-1; $msoFalse=0
$alignLeft=1; $alignCenter=2; $alignRight=3
$W=960; $H=540; $FONT='Segoe UI'

$FIG = "C:\Users\doluwada\DAQIRI_GPU\presentation\figs"
$OUT = "C:\Users\doluwada\DAQIRI_GPU\presentation\NI_technical_review_deck.pptx"

$ppt = New-Object -ComObject PowerPoint.Application
$pres = $ppt.Presentations.Add($msoFalse)
$pres.PageSetup.SlideSize = 15
$pres.PageSetup.SlideWidth = $W
$pres.PageSetup.SlideHeight = $H

function New-Blank {
    $s = $pres.Slides.Add($pres.Slides.Count+1, $blank)
    $s.FollowMasterBackground = $msoFalse
    $s.Background.Fill.Solid(); $s.Background.Fill.ForeColor.RGB = $OffWhite
    return $s
}
function Add-Rect($s,$l,$t,$w,$h,$color){
    $sh = $s.Shapes.AddShape($rect,$l,$t,$w,$h)
    $sh.Fill.Solid(); $sh.Fill.ForeColor.RGB = $color; $sh.Line.Visible = $msoFalse
    return $sh
}
function Add-Text($s,$l,$t,$w,$h,$text,$size,$bold,$color,$align){
    $tb = $s.Shapes.AddTextbox($msoHoriz,$l,$t,$w,$h)
    $tf = $tb.TextFrame; $tf.WordWrap = $msoTrue
    $tf.MarginLeft=0; $tf.MarginRight=0; $tf.MarginTop=0; $tf.MarginBottom=0
    $tr = $tf.TextRange; $tr.Text = $text
    $tr.Font.Name = $FONT; $tr.Font.Size = $size
    $tr.Font.Bold = $(if($bold){$msoTrue}else{$msoFalse})
    $tr.Font.Color.RGB = $color; $tr.ParagraphFormat.Alignment = $align
    return $tb
}
function Add-Header($s,$title,$kicker){
    Add-Rect $s 0 0 10 $H $NIGreen | Out-Null
    Add-Text $s 54 26 840 24 $kicker 12 $true $NIGreen $alignLeft | Out-Null
    Add-Text $s 54 48 840 52 $title 26 $true $Charcoal $alignLeft | Out-Null
    Add-Rect $s 56 100 70 4 $NIGreen | Out-Null
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
    $tr = $tf.TextRange; $tr.Text = ($items -join "`r")
    $tr.Font.Name=$FONT; $tr.Font.Size=$size; $tr.Font.Color.RGB=$Charcoal
    $tr.ParagraphFormat.Alignment=$alignLeft
    $tr.ParagraphFormat.Bullet.Visible=$msoTrue
    $tr.ParagraphFormat.Bullet.Character=8226
    $tr.ParagraphFormat.Bullet.Font.Color.RGB=$NIGreen
    $tr.ParagraphFormat.SpaceAfter=10
    return $tb
}
function Add-Table($s,$l,$t,$w,$h,$rows,$cols,$data,$hlCol){
    $shp = $s.Shapes.AddTable($rows,$cols,$l,$t,$w,$h); $tbl = $shp.Table
    for($r=1;$r -le $rows;$r++){
        for($c=1;$c -le $cols;$c++){
            $cell = $tbl.Cell($r,$c); $tr = $cell.Shape.TextFrame.TextRange
            $tr.Text = [string]$data[$r-1][$c-1]
            $tr.Font.Name=$FONT; $tr.Font.Size=12
            $cell.Shape.TextFrame.MarginTop=3; $cell.Shape.TextFrame.MarginBottom=3
            if($r -eq 1){
                $cell.Shape.Fill.ForeColor.RGB=$NIGreen
                $tr.Font.Color.RGB=$White; $tr.Font.Bold=$msoTrue
            } else {
                $tr.Font.Color.RGB=$Charcoal
                if($hlCol -and ($c -eq $hlCol)){
                    $cell.Shape.Fill.ForeColor.RGB=$LightGrn; $tr.Font.Bold=$msoTrue; $tr.Font.Color.RGB=$NIGrnD
                } else { $cell.Shape.Fill.ForeColor.RGB=$White }
            }
        }
    }
    return $shp
}
# status pill
function Add-Pill($s,$l,$t,$text,$color){
    $w = 96
    Add-Rect $s $l $t $w 24 $color | Out-Null
    Add-Text $s $l ($t+3) $w 18 $text 11 $true $White $alignCenter | Out-Null
}

# =====================================================================
# 1 - Title
# =====================================================================
$s = New-Blank
Add-Rect $s 0 0 $W $H $Charcoal | Out-Null
Add-Rect $s 0 0 12 $H $NIGreen | Out-Null
Add-Text $s 70 150 820 130 "Transport Benchmark for`r Hardware-to-GPU Inference" 40 $true $White $alignLeft | Out-Null
Add-Text $s 74 288 820 30 "Technical Design Review  -  gRPC-Direct and NVIDIA DAQiri, TCP / shared memory / RDMA / GPU FFT" 16 $false $NIGreen $alignLeft | Out-Null
Add-Text $s 74 360 820 24 "Presenter: Dami Thomas   -   NI Summer 2026   -   2026-07-29" 13 $false $White $alignLeft | Out-Null
Add-Text $s 74 388 820 24 "Classification: NI Internal   -   Review type: Results and open-issue review" 12 $false $Slate $alignLeft | Out-Null

# =====================================================================
# 2 - Agenda / Review Scope
# =====================================================================
$s = New-Blank
Add-Header $s "Agenda and Review Scope" "OVERVIEW"
Add-Bullets $s 54 130 850 380 @(
 "Objectives and success criteria",
 "Background: transports, zero-copy, and the GPU FFT pipeline",
 "System architecture and data path",
 "Test configuration and measurement methodology",
 "Phase 1 results: transport benchmark (latency, throughput, RDMA)",
 "Phase 2 results: DAQiri vs gRPC-Direct GPU FFT pipeline",
 "Part 3: closing the gap. Root cause, the remainder, the memory finding, and the RDMA receiver",
 "Open-issue analysis: large-payload delivery",
 "Risk, limitations, conclusions, verification status, and action items") 17 | Out-Null

# =====================================================================
# 3 - Objectives & Success Criteria
# =====================================================================
$s = New-Blank
Add-Header $s "Objectives and Success Criteria" "MIL-STD / NASA REVIEW"
Add-Text $s 54 122 850 22 "Objective" 15 $true $NIGrnD $alignLeft | Out-Null
Add-Bullets $s 54 146 850 96 @(
 "Quantify the latency and throughput cost of the data transport in a live hardware-to-GPU inference path",
 "Compare NI gRPC-Direct against standard gRPC and against NVIDIA DAQiri under matched conditions") 15 | Out-Null
Add-Text $s 54 250 850 22 "Success Criteria" 15 $true $NIGrnD $alignLeft | Out-Null
$sc = @(
 @("ID","Criterion","Result"),
 @("SC-1","Measure transport latency with a fair, repeatable method","MET"),
 @("SC-2","Show transport-only speedup with unchanged application API","MET (up to 281x)"),
 @("SC-3","Compare GPU-pipeline latency, DAQiri vs gRPC-Direct","MET (DAQiri faster all sizes)"),
 @("SC-4","Characterize delivery / drops across payload sizes","MET (128 KB drop found)"),
 @("SC-5","Find and fix the cause of the large-payload gap","MET (1.80x at 4 MB)"),
 @("SC-6","Localize whatever remains to a named component","MET (79 percent inside cuFFT)"))
Add-Table $s 54 268 850 200 7 3 $sc 3 | Out-Null
Add-Footnote $s "Verification status detailed on the conclusions slide."

# =====================================================================
# 4 - Background & Definitions
# =====================================================================
$s = New-Blank
Add-Header $s "Background and Definitions" "CONTEXT"
Add-Bullets $s 54 130 850 380 @(
 "Standard gRPC over TCP: general-purpose RPC; kernel, scheduler and serialization overhead dominate small payloads",
 "gRPC-Direct: NI transport that keeps the gRPC API but swaps TCP for shared memory, low-latency TCP, or RDMA",
 "NVIDIA DAQiri: purpose-built data-acquisition framework with a kernel-bypass NIC-to-GPU path and a portable socket engine",
 "Zero-copy: serialize data directly into the transport buffer, removing host-side memory copies",
 "GPU FFT pipeline: receive buffer -> host-to-device transfer -> cuFFT -> report end-to-end latency",
 "Metric: p50 (median) end-to-end latency per buffer; delivery = buffers received of those sent") 17 | Out-Null

# =====================================================================
# 5 - System Architecture / Data Path
# =====================================================================
$s = New-Blank
Add-Header $s "System Architecture and Data Path" "ARCHITECTURE"
# simple pipeline diagram
$y = 200
Add-Rect $s 40  $y 150 70 $Slate | Out-Null
Add-Text $s 40 ($y+18) 150 40 "Instrument /`rSignal source" 13 $true $White $alignCenter | Out-Null
Add-Rect $s 240 $y 170 70 $NIGreen | Out-Null
Add-Text $s 240 ($y+12) 170 50 "Transport`r(shmem / RDMA /`rDAQiri socket)" 12 $true $White $alignCenter | Out-Null
Add-Rect $s 460 $y 150 70 $Amber | Out-Null
Add-Text $s 460 ($y+12) 150 50 "Host to device`rtransfer`r(H2D copy)" 12 $true $White $alignCenter | Out-Null
Add-Rect $s 660 $y 150 70 $NIGrnD | Out-Null
Add-Text $s 660 ($y+18) 150 40 "GPU FFT`r(cuFFT)" 13 $true $White $alignCenter | Out-Null
foreach($x in @(195,415,615)){ Add-Text $s $x ($y+22) 44 30 ">" 30 $true $Slate $alignCenter | Out-Null }
Add-Bullets $s 54 310 850 170 @(
 "Zero-copy removes the large host-side CPU copy at the transport boundary",
 "gRPC-Direct zero-copy still performs one small device-side realign copy where required; DAQiri buffers are already aligned",
 "Both pipelines are paced identically so the GPU sees the same duty cycle (clock-fair comparison)") 16 | Out-Null
Add-Footnote $s "Timing window for p50 excludes transport receive; it spans H2D transfer through FFT completion."

# =====================================================================
# 6 - Test Configuration
# =====================================================================
$s = New-Blank
Add-Header $s "Test Configuration" "MIL-STD TEST SETUP"
$hw = @(
 @("Item","Configuration"),
 @("Compute node","NVIDIA DGX Spark (spark-ac69), Grace-Blackwell GB10, unified memory"),
 @("Second node","NI PXIe-8881, x86_64, NI Linux Real-Time"),
 @("Interconnect","50G RoCE dedicated link + 10G L2 management network"),
 @("GPU / FFT","cuFFT R2C, CUDA 13; 16-byte-aligned input"),
 @("Signal","Sum of sines (500/1200/2500 Hz) + noise, 1 MHz sample rate"),
 @("Transports","standard gRPC, gRPC-Direct shmem / TCP-LL / RDMA, DAQiri socket"),
 @("Payloads","4K/8K/16K/32K samples = 16 / 32 / 64 / 128 KB"))
Add-Table $s 54 122 850 300 8 2 $hw 0 | Out-Null
Add-Footnote $s "GPU clocks are not lockable on this platform (>10x DVFS swing); addressed by pacing (see methodology)."

# =====================================================================
# 7 - Methodology
# =====================================================================
$s = New-Blank
Add-Header $s "Measurement Methodology (Airtight A/B)" "METHOD"
Add-Bullets $s 54 130 850 380 @(
 "Matched-pair design: both pipelines run the identical workload and payload sweep",
 "Identical pacing at 400 microseconds per buffer to neutralize GPU frequency scaling (DVFS)",
 "On-GPU FFT execution time used as a clock-match probe; near-equal FFT p50 confirms fair clocks",
 "1000 measured buffers per run, 100 warmup discarded, 5 trials per cell",
 "Report the median-of-trials of each per-run p50; latency and delivery reported separately",
 "CPU pinning applied; server processes isolated to avoid scheduler cross-talk") 17 | Out-Null
Add-Footnote $s "Rationale: clocks cannot be locked, so pacing equalizes duty cycle and FFT time verifies the match."

# =====================================================================
# 8 - Phase 1 latency
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 1 - Small-Payload Latency" "RESULTS / TRANSPORT"
Add-Picture $s "$FIG\p1_latency.png" 40 118 560 380 | Out-Null
Add-Bullets $s 620 150 300 320 @(
 "Standard gRPC baseline ~1,000 us (p50)",
 "shmem: 3.3 us  = 281x faster",
 "TCP low-latency: 21.2 us = 44x",
 "RDMA (50G): 36.8 us = 29x",
 "Same gRPC API; only the transport changes") 15 | Out-Null
Add-Footnote $s "Echo round-trip p50, C++ interceptor path."

# =====================================================================
# 9 - Phase 1 throughput
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 1 - Zero-Copy Streaming Throughput" "RESULTS / TRANSPORT"
Add-Picture $s "$FIG\p1_throughput.png" 40 118 520 380 | Out-Null
Add-Bullets $s 590 160 330 300 @(
 "Standard gRPC copy path: 1.78 GB/s",
 "gRPC-Direct shmem zero-copy: 23.59 GB/s",
 "3.9x gain from removing two heap copies per message",
 "Zero-copy effective in C++ (loan buffer + in-place serialization); Python retains a residual copy") 15 | Out-Null
Add-Footnote $s "ReadContinuously streaming, steady state."

# =====================================================================
# 10 - Phase 1 RDMA vs line rate / DAQiri
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 1 - RDMA vs Line Rate" "RESULTS / TRANSPORT"
Add-Picture $s "$FIG\p1_rdma_linerate.png" 40 118 520 380 | Out-Null
Add-Bullets $s 590 160 330 300 @(
 "The first run measured 5.786 GB/s and was read as a fabric limit",
 "It was a 1024-byte RoCE MTU, a misconfiguration, not the API",
 "Same link at MTU 4096: 6.127 GB/s = 98.0% of 50G line rate",
 "A 2-byte control did not move, which attributes the gain to the MTU",
 "The old DAQiri bar is removed: it was the same misconfigured fabric") 15 | Out-Null
Add-Footnote $s "Raw ib_write_bw, 4 MB, PXI writing into the Spark. The DAQiri tie this slide used to assert is retracted; see handoff 7p."

# =====================================================================
# 11 - Phase 2 zero-copy latency
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 2 - GPU Pipeline Latency (Zero-Copy)" "RESULTS / GPU PIPELINE"
Add-Picture $s "$FIG\p2_zerocopy_latency.png" 40 118 580 380 | Out-Null
Add-Bullets $s 640 160 290 300 @(
 "DAQiri lower p50 at every payload",
 "Advantage: +64% (16 KB) to +27% (128 KB)",
 "FFT p50 matched A vs B: clocks fair",
 "Median of 5 trials, paced 400 us") 15 | Out-Null
Add-Footnote $s "End-to-end p50; transport receive excluded from timing window."

# =====================================================================
# 12 - Phase 2 copy penalty
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 2 - Removing the CPU Copy" "RESULTS / GPU PIPELINE"
Add-Picture $s "$FIG\p2_copy_penalty.png" 40 118 580 380 | Out-Null
Add-Bullets $s 640 160 290 300 @(
 "Copy path pays ~117-131 us host staging",
 "Zero-copy removes the large CPU copy",
 "gRPC-Direct copy p50: 136-160 us",
 "gRPC-Direct zero-copy p50: 17-26 us") 15 | Out-Null
Add-Footnote $s "One small device-side realign copy remains in zero-copy mode."

# =====================================================================
# 13 - Phase 2 four-way head-to-head
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 2 - Four-Way Head-to-Head" "RESULTS / GPU PIPELINE"
Add-Picture $s "$FIG\p2_headtohead.png" 90 118 780 390 | Out-Null
Add-Footnote $s "DAQiri copy is far cheaper than gRPC copy (no host staging); zero-copy narrows but DAQiri still leads."

# =====================================================================
# 14 - Phase 2 delivery / drop
# =====================================================================
$s = New-Blank
Add-Header $s "Phase 2 - Delivery and the 128 KB Drop" "RESULTS / GPU PIPELINE"
Add-Picture $s "$FIG\p2_delivery.png" 40 118 580 380 | Out-Null
Add-Bullets $s 640 150 290 320 @(
 "16-64 KB: full delivery (~1000)",
 "128 KB DAQiri copy: ~124 delivered",
 "128 KB DAQiri zero-copy: ~240",
 "gRPC-Direct: ~973 at all sizes",
 "Latency of delivered buffers stays valid") 15 | Out-Null
Add-Footnote $s "128 KB = 32768 samples x 4 bytes = 131072 B (fits under configured max payload 131136 B)."

# =====================================================================
# PART 3 - Closing the gap. Six slides, 14a through 14f.
# Every chart here is regenerated from a CSV in data/ by
# scripts/make_part3_figs.py. No number on these slides is typed in by hand.
# =====================================================================

# ---------------------------------------------------------------------
# 14a - Where the gap was, and how we found it
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "Where the Gap Was, and How We Found It" "PART 3 / LOCALIZING"
Add-Picture $s "$FIG\p3_s1_residual_vs_payload.png" 34 116 560 390 | Out-Null
Add-Bullets $s 614 138 310 350 @(
 "Residual = end-to-end minus the measured transform time",
 "A cost that does not change with payload is fixed overhead",
 "A cost that grows with the byte count means something is touching every byte",
 "DAQiri stays flat, 4.87 to 5.13 us, across a 256x range of payload",
 "gRPC-Direct climbs to 81.88 us at 4 MB",
 "The shape identified a per-byte cost before we knew what it was") 14 | Out-Null
Add-Footnote $s "Source: data/headline_runs.csv, 9 payload sizes, 2 reps per cell. The 4 MB effect is roughly 20x the measured noise floor."

# ---------------------------------------------------------------------
# 14b - The root cause
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "Root Cause: an Alignment Test That Could Not Pass" "PART 3 / ROOT CAUSE"
Add-Picture $s "$FIG\p3_s2_root_cause.png" 34 116 500 390 | Out-Null
Add-Bullets $s 556 132 368 300 @(
 "protobuf guarantees 8-byte alignment for its arena buffers",
 "The zero-copy path tested for 16-byte alignment before using the buffer in place",
 "Every message failed that test and took a staging copy that cuFFT never required",
 "It hid because the timer around cudaMemcpyAsync read 3.5 us: that call only enqueues, so the cost landed outside the window being measured") 14 | Out-Null
Add-Rect $s 556 446 368 62 $LightGrn | Out-Null
Add-Text $s 570 456 340 44 "Copy measured directly: 77.01 us.  Residual gap predicted: 76.53 us.  Two independent measurements of the same cost." 13 $true $NIGrnD $alignLeft | Out-Null
Add-Footnote $s "4 MB payload. DAQiri shown as a reference line, not a competitor: the claim on this slide is what the fix did to gRPC-Direct."

# ---------------------------------------------------------------------
# 14c - What was left, and where it lives
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "What Was Left, and Where It Lives" "PART 3 / THE REMAINDER"
Add-Picture $s "$FIG\p3_s3_where_it_lives.png" 34 116 560 380 | Out-Null
Add-Bullets $s 614 138 310 350 @(
 "After the fix, gRPC-Direct is still about 8 us behind at 4 MB",
 "Split that remainder into the part inside cuFFT and the part outside it",
 "Kernel launch overhead does not depend on payload, so a remainder that grows with the byte count is not launch overhead",
 "At 4 MB, 6.40 us of 8.10 us, about 79 percent, is inside cuFFT itself",
 "Same GPU, same plan, same transform size. What differs is where the input buffer lives") 14 | Out-Null
Add-Footnote $s "Source: data/headline_runs.csv, 2 reps per cell. The dips at 128 KB and 512 KB are rep-to-rep noise at that count, not structure."

# ---------------------------------------------------------------------
# 14d - The memory finding
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "The Memory Finding: a Result That Inverted" "PART 3 / SCOPING"
Add-Picture $s "$FIG\p3_s4_memory.png" 34 112 540 340 | Out-Null
Add-Bullets $s 592 128 332 300 @(
 "Two ways to get host memory the GPU can read: allocated by cudaHostAlloc, or adopted by registering pages the process already owns",
 "Adopted measured slower every way it was tried: 7.3 us in the chart at left, and 10.94 us in a separate 15-rep rotation across page sizes",
 "Then the CPU write that filled the buffer was removed, and the sign inverted: adopted became 11.2 us faster",
 "Confirmed in the real RDMA receiver, where the NIC writes and the CPU never touches the buffer: the two are indistinguishable, p = 1.0") 13 | Out-Null
Add-Rect $s 34 462 890 48 $LightAmb | Out-Null
Add-Text $s 48 472 862 32 "Both measurements were correct about what they measured. The error available here was carrying one of them into a configuration it had not measured, which is the configuration that ships." 13 $true $Charcoal $alignLeft | Out-Null
Add-Footnote $s "Sources: data/memsrc_2x2_1048576.csv, data/memsrc_2x2_nowrite_1048576.csv, data/pagesize_rot.csv. 4 MiB payload. Error bars are distribution-free intervals of the median."

# ---------------------------------------------------------------------
# 14e - What got built. Data-path diagram, not a chart.
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "What Got Built: RDMA Straight into GPU-Readable Memory" "PART 3 / THE TRANSPORT"

$bx = 42; $by = 150; $bw = 132; $bh = 62; $gap = 24
Add-Rect $s $bx $by $bw $bh $Slate | Out-Null
Add-Text $s ($bx+8) ($by+14) ($bw-16) 40 "PXI chassis`r(no CUDA)" 13 $true $White $alignCenter | Out-Null
$x2 = $bx + $bw + $gap
Add-Rect $s $x2 $by $bw $bh $NIGrnD | Out-Null
Add-Text $s ($x2+8) ($by+14) ($bw-16) 40 "50G RoCE`rlink" 13 $true $White $alignCenter | Out-Null
$x3 = $x2 + $bw + $gap
Add-Rect $s $x3 $by $bw $bh $NIGrnD | Out-Null
Add-Text $s ($x3+8) ($by+14) ($bw-16) 40 "NIC writes`rby DMA" 13 $true $White $alignCenter | Out-Null
$x4 = $x3 + $bw + $gap
Add-Rect $s $x4 $by ($bw+40) $bh $NIGreen | Out-Null
Add-Text $s ($x4+8) ($by+8) ($bw+24) 50 "One host buffer:`rcudaHostAlloc + ibv_reg_mr" 12 $true $White $alignCenter | Out-Null
$x5 = $x4 + $bw + 40 + $gap
Add-Rect $s $x5 $by $bw $bh $Charcoal | Out-Null
Add-Text $s ($x5+8) ($by+14) ($bw-16) 40 "cuFFT reads`rin place" 13 $true $White $alignCenter | Out-Null

Add-Text $s 42 232 880 24 "No staging copy anywhere on this path. The NIC and the GPU address the same allocation." 14 $true $NIGrnD $alignLeft | Out-Null

# Flow connectors, drawn after the boxes so they sit in the gaps between them.
foreach($ax in @(($bx+$bw), ($x2+$bw), ($x3+$bw), ($x4+$bw+40))){
    Add-Text $s $ax ($by+16) $gap 30 ">" 26 $true $Slate $alignCenter | Out-Null
}

Add-Bullets $s 42 274 430 230 @(
 "GPUDirect RDMA is not available on GB10: unified memory means there is no separate GPU aperture for the NIC to target",
 "Registering a cudaHostAlloc buffer with the NIC is the supported route on this hardware",
 "The receiver runs the transform on a dedicated CUDA stream") 14 | Out-Null
Add-Bullets $s 500 274 424 230 @(
 "Measured at 98.0 percent of 50G line rate, once the RoCE MTU was corrected",
 "Runs PXI to Spark. DAQiri cannot: it requires CUDA on both ends, and the PXI chassis has no GPU",
 "That is a capability difference, not a latency difference") 14 | Out-Null
Add-Footnote $s "Throughput from ib_write_bw, 4 MB writes, PXI to Spark. Latency numbers for this transport are on the next slide."

# ---------------------------------------------------------------------
# 14f - Where it ended
# ---------------------------------------------------------------------
$s = New-Blank
Add-Header $s "Where It Ended: Four Arms at 4 MiB" "PART 3 / RESULT"
Add-Picture $s "$FIG\p3_s6_four_arm_sat.png" 34 116 560 380 | Out-Null
Add-Bullets $s 614 132 310 300 @(
 "12 reps per arm, each arm rotated through all four running positions",
 "Error bars are distribution-free intervals of the median, so the chart shows what the measurement can and cannot resolve",
 "gRPC-Direct is 1.71x faster than it was, and now sits 6.96 us behind DAQiri (12 of 12 reps, interval 5.31 to 9.41 us)",
 "That 6.96 us does not depend on how hard the arms are driven: the same test at an eight times lower offered rate gives 7.02 us",
 "The before arm has the fastest transform because it reads device memory after paying a 77 us copy to get there") 13 | Out-Null
Add-Rect $s 614 438 310 70 $LightAmb | Out-Null
Add-Text $s 626 446 286 56 "Only the RDMA arm cares about offered rate: 23 us between the two pacing regimes, against under 2 us for every other arm." 12 $true $Charcoal $alignLeft | Out-Null
Add-Footnote $s "Source: data/deck_4arm_4mib.csv, saturated regime. 4 MiB payload, 1000 messages per cell, SM clock gated at 2400 MHz and recorded per cell. The unsaturated regime was measured at the same rep count and is the sensitivity result quoted above."

# =====================================================================
# 15 - Open Issue Analysis
# =====================================================================
$s = New-Blank
Add-Header $s "Open Issue: 128 KB Delivery Analysis" "OPEN ITEM"
Add-Pill $s 800 30 "OPEN" $Amber
Add-Text $s 54 120 850 20 "Observation" 14 $true $NIGrnD $alignLeft | Out-Null
Add-Text $s 54 142 850 34 "DAQiri delivers only ~12-24% of buffers at 128 KB over the TCP loopback socket engine; gRPC-Direct is unaffected." 14 $false $Charcoal $alignLeft | Out-Null
Add-Text $s 54 186 850 20 "Candidate hypotheses (to test)" 14 $true $NIGrnD $alignLeft | Out-Null
Add-Bullets $s 54 208 850 170 @(
 "Send-side vs receive-side: capture TX-sent vs RX-received counts (the binary prints both plus engine stats)",
 "Socket buffer limits: raise SO_SNDBUF / SO_RCVBUF via DAQiri socket_setsockopt (no sudo required)",
 "Configuration: revisit num_bufs, batch_size, and max_payload_size headroom in the YAML",
 "Transport ceiling: a genuine TCP-loopback limit at this payload (flagship kernel-bypass path would differ)") 14 | Out-Null
Add-Text $s 54 392 850 20 "Diagnostic plan" 14 $true $NIGrnD $alignLeft | Out-Null
Add-Bullets $s 54 414 850 90 @(
 "Foreground 128 KB run capturing full summary to isolate send vs receive (Step 1)",
 "Apply no-sudo socket tuning symmetrically, re-run (Step 2); if drops persist, document as transport ceiling (Step 3)") 14 | Out-Null
Add-Footnote $s "Blocked on test-hardware availability; hardware relocated 2026-07."

# =====================================================================
# 16 - Risk & Limitations
# =====================================================================
$s = New-Blank
Add-Header $s "Risk and Limitations" "MIL-STD RISK"
$rk = @(
 @("Area","Limitation","Mitigation"),
 @("GPU clocks","Not lockable, >10x DVFS swing","Clocks warmed to 2400 MHz and recorded per cell"),
 @("Topology","Part 3 arms all run same-box, DAQiri as an RC loopback","Same for every arm, which is what makes them comparable"),
 @("Offered rate","The RDMA arm moves 23 us between pacing regimes; no other arm moves more than 2 us","Both regimes measured at 12 reps; the headline names the one it uses"),
 @("Delivery","128 KB drop on DAQiri (open)","Diagnostic plan defined; latency unaffected"),
 @("Rep count","Slides on payload shape rest on 2 reps per cell","Rep count printed on those slides; 4 MiB conclusions use 12"))
Add-Table $s 54 122 850 230 6 3 $rk 0 | Out-Null
Add-Bullets $s 54 368 850 130 @(
 "Latency medians are robust to the drop (drops reduce sample count, not the median of delivered buffers)",
 "Throughput and reliability at 128 KB is the only affected result and is flagged as open") 14 | Out-Null

# =====================================================================
# 17 - Conclusions & Verification Status
# =====================================================================
$s = New-Blank
Add-Header $s "Conclusions and Verification Status" "CLOSURE"
$cv = @(
 @("Finding","Status"),
 @("Transport swap gives up to 281x lower latency, same API","VERIFIED"),
 @("Zero-copy gives 3.9x streaming throughput","VERIFIED"),
 @("RDMA transport runs at 98.0 percent of 50G line rate","VERIFIED"),
 @("Earlier claim that RDMA ties DAQiri at the fabric limit","RETRACTED - measured a misconfigured MTU"),
 @("Large-payload root cause found and fixed: 1.80x at 4 MB","VERIFIED"),
 @("Remaining gap to DAQiri at 4 MiB: 6.96 us, 12 of 12 reps","VERIFIED"),
 @("Host memory choice is neutral when the CPU does not write","VERIFIED"),
 @("128 KB DAQiri delivery limit","OPEN - under analysis"))
Add-Table $s 54 118 850 268 9 2 $cv 0 | Out-Null
Add-Bullets $s 54 400 850 110 @(
 "Transport, not compute, governs hardware-to-GPU latency. The remaining difference at 4 MiB is about 7 us and is located inside cuFFT, not in the API",
 "One delivery item remains open before full sign-off") 14 | Out-Null

# =====================================================================
# 18 - Next Steps / Action Items
# =====================================================================
$s = New-Blank
Add-Header $s "Action Items and Next Steps" "ACTIONS"
$ai = @(
 @("#","Action","Owner","Depends on"),
 @("1","Foreground 128 KB run: isolate send vs receive","D. Thomas","Hardware online"),
 @("2","No-sudo socket tuning, symmetric re-run","D. Thomas","Item 1"),
 @("3","Validate on flagship NIC-to-GPU path","D. Thomas","SmartNIC access"),
 @("4","Package transport recommendation for NI teams","D. Thomas","Items 1-3"))
Add-Table $s 54 122 850 190 5 4 $ai 0 | Out-Null
Add-Footnote $s "Current blocker: DGX Spark and PXI test systems relocated; work resumes when reachable."

# =====================================================================
# 19 - Backup: Aggregated Data Table
# =====================================================================
$s = New-Blank
Add-Header $s "Backup - Aggregated Phase 2 Data (median of 5 trials)" "BACKUP"
$dt = @(
 @("Payload","Pipeline / mode","Deliv","E2E p50 (us)","FFT p50 (us)","MB/s"),
 @("16 KB","DAQiri zero-copy","1000","10.22","5.15","1602"),
 @("16 KB","gRPC-Direct zero-copy","972","16.77","8.61","977"),
 @("32 KB","DAQiri zero-copy","1000","11.94","6.85","2749"),
 @("32 KB","gRPC-Direct zero-copy","972","17.36","8.51","1888"),
 @("64 KB","DAQiri zero-copy","1000","14.22","9.15","4607"),
 @("64 KB","gRPC-Direct zero-copy","971","21.38","11.58","3066"),
 @("128 KB","DAQiri zero-copy","240","20.78","15.78","6316"),
 @("128 KB","gRPC-Direct zero-copy","973","26.48","15.52","4950"))
Add-Table $s 54 118 850 330 9 6 $dt 4 | Out-Null
Add-Footnote $s "Copy-mode rows and Phase 1 detail available in the project repository (data/ and README)."

# ---- save ----
$pres.SaveAs($OUT, 24)
$pres.Close()
$ppt.Quit()
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($ppt) | Out-Null
Write-Output "SAVED: $OUT"
