# Writes speaker notes into Intern_showcase_Dami.pptx.
#
# Slides are matched by a distinctive substring of their headline, not by index,
# because the slide numbers have already moved twice. If a slide is not found
# the script says so instead of writing the notes onto the wrong slide.
#
# Re-running overwrites the notes. It does not touch anything on the slide.

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

$notes["faster at every size"] = @(
 "[70 sec]",
 "This is the comparison that set up the rest of my summer.",
 "Time for one buffer to go from arrival to a finished FFT, at four payload sizes. DAQiri is ahead at every one, by 27 to 64 percent.",
 "Notice that Part 1 and Part 2 point different ways. On throughput the two are close. On per-buffer latency they aren't. Those are genuinely different questions. Throughput asks how much fits down the pipe. Latency asks how long one thing takes to get through. A system can be good at one and bad at the other.",
 "So: why is DAQiri ahead? That's Part 3."
)

$notes["told me where to look"] = @(
 "[75 sec]",
 "The trick on this slide is simple. Take the total time, subtract the FFT time. What's left is everything the pipeline does around the math.",
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
 "[70 sec]",
 "This is what I built.",
 "On this chip, GPUDirect, where the card writes straight into GPU memory, isn't available. So the supported route is one host buffer registered twice: once with the network card, once with CUDA. Same bytes, two owners.",
 "The card writes into it directly. cuFFT reads it where it landed. Nothing is staged anywhere.",
 "The part that matters commercially is the first box. The instrument chassis has no NVIDIA GPU in it. DAQiri needs CUDA at both ends, so DAQiri cannot make this trip at all. This path can, at 98 percent of line rate."
)

$notes["Where it ended"] = @(
 "[80 sec]",
 "Four transports, 4 megabyte buffers, twelve repetitions each, and every transport ran in all four positions so nobody got the good slot.",
 "The whiskers are what the measurement can actually resolve. That matters, because the noise floor here is about 4 microseconds, which is why three repetitions would have told me nothing.",
 "gRPC Direct is 1.71 times faster than it started and sits about 7 microseconds behind DAQiri. It lost all twelve. I ran the whole test again at an eighth of the data rate and got 7 again, so that answer doesn't depend on how hard I drive it.",
 "One thing I can't explain yet: the RDMA arm moves 23 microseconds between those two rates and nothing else moves 2. That's the open question I'm handing over.",
 "And read the footnote out loud. All four run on one machine, so this is the software cost with the wire taken out."
)

$notes["Summary"] = @(
 "[60 sec]",
 "Where this leaves us.",
 "Same application code, a much faster path underneath it. A transport that reaches 98 percent of line rate from a chassis with no GPU in it, which the alternative cannot do at all.",
 "In the GPU pipeline, a real root cause worth 1.71 times, and the remainder localized to inside the FFT library rather than the transport.",
 "I did not close the gap to DAQiri. I found out precisely where the rest of it lives. I'd rather tell you that than tell you I closed it.",
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

    $body = $null
    foreach ($sh in $s.NotesPage.Shapes) {
        if ($sh.HasTextFrame -eq -1 -and $sh.Height -gt 100) { $body = $sh }
    }
    if (-not $body) { Write-Host ("  slide {0}: no notes placeholder" -f $i); continue }
    $body.TextFrame.TextRange.Text = ($notes[$hit] -join "`r")
    $body.TextFrame.TextRange.Font.Size = 12
    Write-Host ("  slide {0}: {1}" -f $i, $hit)
}

foreach ($k in $notes.Keys) {
    if (-not $used.ContainsKey($k)) { Write-Host ("  UNPLACED: {0}" -f $k) }
}

$deck.Save()
Write-Host "SAVED: $($deck.FullName)"
