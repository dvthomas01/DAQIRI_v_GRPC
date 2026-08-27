<#
  Writes speaker notes into Intern_showcase_Dami.pptx.

  Slides are matched by a distinctive substring of their headline, not by index,
  because the slide numbers have already moved twice. If a slide is not found
  the script says so instead of writing the notes onto the wrong slide.

  IT WILL NOT OVERWRITE NOTES YOU WROTE YOURSELF. An earlier version of this
  script rewrote all fourteen notes pages on every run, which flattened hand
  written notes without saying so. Now a notes page that already has text is
  left alone unless you name it, and every run dumps the notes as they were
  before it touched anything.

    .\add_speaker_notes.ps1
        Fills in empty notes pages only. Anything you have written is kept.

    .\add_speaker_notes.ps1 -Only "Where it ended"
        Rewrites that one slide, whatever is on it. Takes several keys.

    .\add_speaker_notes.ps1 -Force
        Rewrites all of them. The backup is your way out.

  Backups land in presentation\notes_backup\ and are not committed.
#>

param(
    [string[]]$Only = @(),
    [switch]$Force
)

$DeckPath = "C:\Users\doluwada\DAQIRI_GPU\presentation\Intern_showcase_Dami.pptx"

$app = $null
try { $app = [Runtime.InteropServices.Marshal]::GetActiveObject("PowerPoint.Application") } catch { }
if (-not $app) { $app = New-Object -ComObject PowerPoint.Application }
$deck = $null
foreach ($p in $app.Presentations) { if ($p.FullName -eq $DeckPath) { $deck = $p } }
if (-not $deck) { $deck = $app.Presentations.Open($DeckPath) }

# Ordered so the report prints in deck order.
$notes = [ordered]@{}

$notes["Getting Live Hardware"] = @(
 "[20 sec]",
 "I'm Dami. I spent the summer on one question: when an instrument is producing data without stopping, how long does it take to get that data into a GPU, and what is actually eating the time.",
 "I'll go through the path in two stages, then what I did about the gap I found."
)

$notes["data path, not the math"] = @(
 "[60 sec]",
 "When GPU work is slow, people assume the math is slow. Usually it isn't. A 4 megabyte FFT on this hardware takes about 60 microseconds. Getting those 4 megabytes to the GPU can take twice that.",
 "So the interesting problem is the plumbing, not the math. I split the path into two stages and measured what each one adds.",
 "Part 1 is the network: instrument to computer. Part 2 is memory: computer to GPU. Part 3 is what I did about what I found in Part 2."
)

$notes["281 times"] = @(
 "[70 sec]",
 "Same application code in all three bars. Only the transport underneath changes.",
 "Standard gRPC over a socket does a round trip in about 929 microseconds. Fast TCP is the same TCP with Nagle's algorithm turned off. Nagle is a rule that holds a small send while it waits for an acknowledgement, which is exactly wrong for send-one-wait-for-reply traffic. Turning it off gets you to 21 microseconds.",
 "Shared memory drops it to 3.3, because the receiver reads the same physical pages the sender wrote. Nothing moves.",
 "Say this out loud: all three are on one machine. This is the software cost, not the wire."
)

$notes["four times the streaming"] = @(
 "[55 sec]",
 "Same idea, but throughput instead of latency, and still one machine.",
 "Standard gRPC copies the payload at least twice: once to serialize it, once for the receiver to unpack it. That caps it near 1.78 gigabytes a second. The zero copy path writes straight into memory the receiver already maps, so nothing is copied, and it runs about four times faster.",
 "One caveat I'd rather say than be caught on: this number comes from an earlier run and I don't have the full conditions written down. The direction is right. Don't hold me to the decimal."
)

$notes["98% of the 50-gigabit"] = @(
 "[70 sec]",
 "Now a real network link.",
 "The math: 50 gigabits per second, divide by 8, gives 6.25 gigabytes per second as the ceiling. We measured 6.13. That's 98 percent.",
 "If someone asks how you reach 98 percent with packet headers in the way: at a 4 kilobyte MTU, the Ethernet, IP, UDP and RoCE headers add up to roughly 82 bytes per packet, which is about 2 percent. So 98 is the ceiling for this frame size, and we're sitting on it.",
 "This is throughput. How long a single buffer takes to arrive is a separate question, and that's Part 2."
)

$notes["skip the big CPU copy"] = @(
 "[60 sec]",
 "Second stage, computer to GPU.",
 "This machine has unified memory, so the CPU and GPU share one pool. A buffer in host memory can be read by the GPU with no transfer at all, if you set it up correctly. Both transports now do that.",
 "That matters for the next slide. From here on, when one is faster than the other, it is not because one is copying and the other isn't. They start level."
)

# Slides 7, 8, 13 and 14 below are transcribed back out of the deck because the
# wording on them is Dami's, not mine. Keep it that way. If the deck and this
# file ever disagree, the deck wins and this file gets updated to match.
$notes["faster at every size"] = @(
 "[70 sec]",
 "This is the comparison between daqiri and grpc direct",
 "Time for one buffer to go from arrival to a finished FFT, at four payload sizes. DAQiri is ahead at every one, by 27 to 64 percent.",
 "Notice that Part 1 and Part 2 point different ways. On throughput the two are close. On per-buffer latency they aren't. Those are genuinely different questions. Throughput asks how much fits down the pipe. Latency asks how long one thing takes to get through. A system can be good at one and bad at the other.",
 "So: why is DAQiri ahead? That's Part 3."
)

$notes["told me where to look"] = @(
 "[75 sec]",
 "The network card finishes writing bytes into a slot",
 "The card posts a completion notice",
 "Your thread sees that notice",
 "timer starts",
 "Your code grabs the pointer for that slot",
 "Launches cuFFT",
 "GPU computes",
 "Your code waits for the GPU",
 "timer stops",
 "The trick on this slide is simple. Take the total time, subtract the FFT time. What's left is everything the pipeline does around the math (steps 5, 6, 8).",
 "Now look at the shape, not the values. DAQiri's leftover time is flat: about 5 microseconds whether the buffer is 16 kilobytes or 4 megabytes. Flat means fixed overhead. A setup step, a launch, a notification. It doesn't care how much data there is.",
 "gRPC Direct's climbs from 8 to 82. A cost that grows with the byte count means something is reading or writing every byte.",
 "So I stopped looking for a slow FFT and started looking for a copy."
)

$notes["alignment check"] = @(
 "[85 sec]",
 "And there was one.",
 "Every location in memory has an address, which is just a number. 16 byte aligned means that number divides evenly by 16. Some wide load instructions prefer that.",
 "Our receiver had a line that said: if this buffer isn't 16 byte aligned, copy it somewhere that is. That looks like careful code. The problem is that protobuf, the library that packs the message, guarantees 8 byte alignment and never promises 16. So the check failed on every single message, forever, and every message paid to copy itself. cuFFT was happy with 8 the whole time.",
 "The fix stops guessing. If the pointer isn't 16 aligned, we ask cuFFT directly whether it will take it. It says yes, and the copy disappears.",
 "Why did this hide for so long? The copy is asynchronous. The call returns when the work is queued, not when the bytes have moved. Our timer read 3.5 microseconds. The real 77 showed up later and got billed to the FFT. Worth remembering: an async API will happily let you time the wrong thing."
)

$notes["inside the FFT library, not"] = @(
 "[65 sec]",
 "That fix was worth 1.71 times. DAQiri is still ahead, so where is the rest of it.",
 "I split the remaining gap in two: the part inside the FFT library and the part outside it. Outside stays under 2 microseconds at every size. Inside grows with the payload, and at 4 megabytes it's 79 percent of what's left.",
 "Launch overhead doesn't grow with payload, so this isn't launch overhead. It points at the buffer itself, at where the data is sitting when cuFFT reads it. Which is what sent me into memory."
)

$notes["inverted when I removed"] = @(
 "[90 sec] Slow down here. This is the slide worth remembering.",
 "There are two ways to get host memory a GPU can read. Let CUDA allocate the pages, or hand CUDA pages your program already owns.",
 "Ours measured slower every way I tried it, by 7 to 11 microseconds, fifteen runs out of fifteen. That result is why I built the RDMA receiver the way I did.",
 "Then I removed one thing from the test: the CPU loop that filled the buffer. The sign flipped. Ours came out 11 microseconds faster.",
 "So I went and measured it in the setup that actually ships, where a network card fills the buffer and no CPU ever touches it. There the two are indistinguishable.",
 "Both of the earlier measurements were correct about what they measured. The mistake on offer was carrying one of them into a configuration it had never seen. I nearly did."
)

$notes["the card writes into memory"] = @(
 "[95 sec]",
 "This is what I built.",
 "On this chip, GPUDirect, where the card writes straight into GPU memory, isn't available. So the supported route is one host buffer registered twice: once with the network card, once with CUDA. Same bytes, two owners.",
 "The card writes into it directly. cuFFT reads it where it landed. Nothing is staged anywhere. On a machine without GPUDirect that is the shortest path there is. There is no version of this that copies less.",
 "On the next slide this path measures about 9 microseconds behind the local shared memory one, and I would rather be the one who says why that is still the result I would keep.",
 "It is the only one of the four that can cross a machine boundary. The other three need the sender and the receiver in the same box. Shared memory has no answer to 'the instrument is over there.'",
 "And DAQiri needs CUDA at both ends. The instrument chassis has no NVIDIA GPU in it. So on the topology we actually ship, the comparison is not 83 against 66. It is 83 against not possible.",
 "It reaches 98 percent of line rate, so the ceiling is the hardware's and not ours. Put a faster link under it and the same code follows the link up.",
 "For scale: moving 4 megabytes across 50 gigabit takes about 670 microseconds on the wire. Nine microseconds of receive-side work is under 2 percent of that. On a real hop it is not the thing you would notice.",
 "And it is built from ordinary supported pieces: RoCE, a standard memory registration, and cudaHostRegister. Nothing here depends on a driver trick, so somebody can maintain it after I leave."
)

$notes["Where it ended"] = @(
 "[100 sec]",
 "Two charts. Left is one payload size with the full treatment.",
 "Right is all nine sizes, and only the two arms that take the same route into the GPU, because those are the pair where a difference tells you something.",
 "Left first. Four transports, 4 megabyte buffers, twelve repetitions each, and every transport ran in all four positions so nobody got the good slot. The whiskers are what the measurement can actually resolve, which matters, because the noise floor here is about 4 microseconds. Three repetitions would have told me nothing.",
 "gRPC Direct is 1.71 times faster than it started and sits about 7 microseconds behind DAQiri. It lost all twelve. I ran the whole test again at an eighth of the data rate and got 7 again, so that answer does not depend on how hard I drive it.",
 "Now the right chart, and this is here because one payload size is a fair thing to object to. 4 megabytes could be the one width where those two happen to land like that. They do not. The gap grows with the payload, from about 1 microsecond at 16 kilobytes to 8 at 4 megabytes, which in proportion is a steady 5 to 16 percent behind across a 256-fold range.",
 "The two charts are separate runs, and I labelled the right one's 4 megabyte points so you can see that. It measured 70.4 and 62.3 where the bars say 74.1 and 66.2. Two reps a point against twelve. They agree on the shape, and I would not quote the right one's decimals.",
 "If somebody subtracts the two bar labels and gets 7.9 while the headline says 7: the headline is the paired difference. All four arms run inside the same repetition, so I take opt minus DAQiri within each repetition and then the median of those twelve differences, which is 6.96. Subtracting two independent medians gives 7.91. The paired one is the right statistic for this design and it is the smaller of the two, so I am not flattering myself with it.",
 "why the RDMA bar is higher than the shared memory bar: it is the only arm that can leave the machine, and it is the only arm the instrument chassis can run, because that chassis has no NVIDIA GPU in it. Slower than a route you cannot take is still the fastest route available.",
 "One thing I cannot explain yet: the RDMA arm moves 23 microseconds between those two data rates and nothing else moves 2. That is the open question I am handing over.",
 "All four run on one machine, so this is software cost with the wire taken out."
)

$notes["Summary"] = @(
 "[60 sec]",
 "Where this leaves us.",
 "Same application code, a much faster path underneath it. A transport that reaches 98 percent of line rate from a chassis with no GPU in it, which the alternative cannot do at all.",
 "In the GPU pipeline, a real root cause worth 1.71 times, and the remainder localized to inside the FFT library rather than the transport.",
 "I did not close the gap to DAQiri, we were able to make a rdma path that is able to go from pxi to spark without any special drivers, or gpus, or cuda kernals, something that daqiri can't do.",
 "Happy to take questions."
)

function Get-Head($slide) {
    $h = ""
    foreach ($sh in $slide.Shapes) {
        if ($sh.Name -eq "TextBox 3" -and $sh.HasTextFrame -eq -1) {
            if ($sh.TextFrame.HasText -eq -1) { $h = $sh.TextFrame.TextRange.Text }
        }
    }
    if ($h -eq "") {
        foreach ($sh in $slide.Shapes) {
            if ($sh.Name -eq "TextBox 2" -and $sh.HasTextFrame -eq -1) {
                if ($sh.TextFrame.HasText -eq -1) { $h = $sh.TextFrame.TextRange.Text }
            }
        }
    }
    if ($h -eq "") {
        foreach ($sh in $slide.Shapes) {
            if ($sh.HasTextFrame -eq -1) {
                if ($sh.TextFrame.HasText -eq -1 -and $h -eq "") {
                    $h = $sh.TextFrame.TextRange.Text
                }
            }
        }
    }
    return ($h -replace "[\r\n]", " ")
}

function Get-NotesBody($slide) {
    $body = $null
    foreach ($sh in $slide.NotesPage.Shapes) {
        if ($sh.HasTextFrame -eq -1 -and $sh.Height -gt 100) { $body = $sh }
    }
    return $body
}

# Dump every notes page exactly as it stands before anything is written. This is
# the safety net: if a run does clobber something, the text is still on disk.
$backupDir = Join-Path $PSScriptRoot "notes_backup"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backupFile = Join-Path $backupDir ("notes_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))
$dump = New-Object System.Text.StringBuilder
for ($i = 1; $i -le $deck.Slides.Count; $i++) {
    $b = Get-NotesBody $deck.Slides.Item($i)
    $txt = ""
    if ($b -and $b.TextFrame.HasText -eq -1) { $txt = $b.TextFrame.TextRange.Text }
    [void]$dump.AppendLine("===== slide $i =====")
    [void]$dump.AppendLine($txt)
}
Set-Content -Path $backupFile -Value $dump.ToString() -Encoding UTF8
Write-Host "backed up existing notes to: $backupFile"

$used = @{}
for ($i = 1; $i -le $deck.Slides.Count; $i++) {
    $s = $deck.Slides.Item($i)
    $head = Get-Head $s
    $hit = $null
    foreach ($k in $notes.Keys) {
        if ($head -like "*$k*" -and -not $used.ContainsKey($k)) { $hit = $k; break }
    }
    if (-not $hit) { Write-Host ("  slide {0}: NO NOTES MATCHED :: {1}" -f $i, $head); continue }
    $used[$hit] = $i

    $body = Get-NotesBody $s
    if (-not $body) { Write-Host ("  slide {0}: no notes placeholder" -f $i); continue }

    $existing = ""
    if ($body.TextFrame.HasText -eq -1) { $existing = $body.TextFrame.TextRange.Text.Trim() }

    $named = $false
    foreach ($o in $Only) { if ($hit -like "*$o*" -or $o -like "*$hit*") { $named = $true } }

    if ($existing -ne "" -and -not $named -and -not $Force) {
        Write-Host ("  slide {0}: KEPT what is already there ({1})" -f $i, $hit)
        continue
    }

    $body.TextFrame.TextRange.Text = ($notes[$hit] -join "`r")
    $body.TextFrame.TextRange.Font.Size = 12
    $how = if ($existing -eq "") { "filled in" } else { "REPLACED" }
    Write-Host ("  slide {0}: {1} ({2})" -f $i, $how, $hit)
}

foreach ($k in $notes.Keys) {
    if (-not $used.ContainsKey($k)) { Write-Host ("  UNPLACED: {0}" -f $k) }
}

$deck.Save()
Write-Host "SAVED: $($deck.FullName)"
