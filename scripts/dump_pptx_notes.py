"""
Dumps the speaker notes out of a .pptx without needing PowerPoint.

Written to find hand-written notes that add_speaker_notes.ps1 overwrote. A pptx
is a zip; ppt/notesSlides/notesSlideN.xml holds the notes page, and the slide it
belongs to is named in its _rels file. Text lives in <a:t> elements.

  python scripts/dump_pptx_notes.py <file.pptx> [more.pptx ...]
"""

import re
import sys
import zipfile


def notes_of(path):
    out = {}
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist()
                 if re.match(r"ppt/notesSlides/notesSlide\d+\.xml$", n)]
        for n in sorted(names, key=lambda s: int(re.search(r"(\d+)", s.rsplit("/", 1)[1]).group(1))):
            xml = z.read(n).decode("utf-8", "replace")
            # Drop the slide-number placeholder's field text, which is just a digit.
            body = re.sub(r"<a:fld[^>]*>.*?</a:fld>", "", xml, flags=re.S)
            paras = re.findall(r"<a:p>(.*?)</a:p>", body, flags=re.S)
            lines = []
            for p in paras:
                t = "".join(re.findall(r"<a:t>(.*?)</a:t>", p, flags=re.S))
                t = (t.replace("&amp;", "&").replace("&lt;", "<")
                      .replace("&gt;", ">").replace("&quot;", '"')
                      .replace("&apos;", "'").strip())
                if t:
                    lines.append(t)
            # Find which slide this notes page belongs to.
            rel = "ppt/notesSlides/_rels/%s.rels" % n.rsplit("/", 1)[1]
            idx = None
            if rel in z.namelist():
                m = re.search(r'Target="\.\./slides/slide(\d+)\.xml"',
                              z.read(rel).decode("utf-8", "replace"))
                if m:
                    idx = int(m.group(1))
            out[idx if idx is not None else n] = lines
    return out


def main():
    for path in sys.argv[1:]:
        print("########## %s" % path)
        try:
            d = notes_of(path)
        except Exception as e:
            print("  unreadable: %s" % e)
            continue
        for k in sorted(d, key=lambda x: (isinstance(x, str), x)):
            print("  ----- slide %s -----" % k)
            for line in d[k]:
                print("    %s" % line)
        print()


if __name__ == "__main__":
    main()
