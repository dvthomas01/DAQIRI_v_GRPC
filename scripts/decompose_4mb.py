import csv, os

sizes = [4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576]


def load(p):
    with open(p) as f:
        return list(csv.DictReader(f))


def pct(vals, q):
    v = sorted(vals)
    return v[min(int(len(v) * q / 100), len(v) - 1)]


def col(rows, name, q=50):
    return pct([float(r[name]) for r in rows], q)


hdr = ("size", "KB", "nR", "nG", "R_e2e", "R_fft", "R_res",
       "G_e2e", "G_fft", "G_res", "d_res", "d_fft", "d_e2e")
print("".join(h.rjust(9) for h in hdr))

for mode in ("zerocopy", "copy"):
    print("\n== %s ==" % mode)
    for s in sizes:
        pr = "data/daqiri_roce_%s_%d.csv" % (mode, s)
        pg = "data/grpc_%s_%d.csv" % (mode, s)
        if not (os.path.exists(pr) and os.path.exists(pg)):
            continue
        R, G = load(pr), load(pg)
        re_, rf = col(R, "e2e_latency_us"), col(R, "fft_exec_us")
        ge, gf = col(G, "e2e_latency_us"), col(G, "fft_exec_us")
        rr, gr = re_ - rf, ge - gf
        vals = [s, s * 4 // 1024, len(R), len(G), re_, rf, rr, ge, gf, gr,
                gr - rr, gf - rf, ge - re_]
        out = []
        for i, v in enumerate(vals):
            out.append(("%d" % v if i < 4 else "%.2f" % v).rjust(9))
        print("".join(out))
