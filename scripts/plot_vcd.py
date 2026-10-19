#!/usr/bin/env python3
"""Render selected VCD signals to a PNG timing diagram (no GTKWave needed).

Usage:
    python scripts/plot_vcd.py results/async_fifo.vcd results/wave_fill.png \
        --start 60 --end 420 \
        --signals tb_async_fifo.wclk tb_async_fifo.winc tb_async_fifo.wdata ...

Times are in ns. Signals are hierarchical names as they appear in the VCD.
"""
import argparse
import re

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def parse_vcd(path, wanted):
    """Return ({name: width}, {name: [(time_ps, value_str)]}, timescale_ps)."""
    id_to_names, widths, scopes = {}, {}, []
    changes = {w: [] for w in wanted}
    ts_ps = 1
    t = 0
    in_header = True
    with open(path) as f:
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if in_header:
                if tok[0] == "$timescale":
                    txt = " ".join(tok[1:]) if len(tok) > 1 else next(f).strip()
                    m = re.match(r"(\d+)\s*(\w+)", txt)
                    mult = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1, "fs": 1e-3}
                    ts_ps = int(m.group(1)) * mult[m.group(2)]
                elif tok[0] == "$scope":
                    scopes.append(tok[2])
                elif tok[0] == "$upscope":
                    scopes.pop()
                elif tok[0] == "$var":
                    width, code, name = int(tok[2]), tok[3], tok[4]
                    full = ".".join(scopes + [name])
                    if full in changes:
                        id_to_names.setdefault(code, []).append(full)
                        widths[full] = width
                elif tok[0] == "$enddefinitions":
                    in_header = False
                continue
            c = tok[0][0]
            if c == "#":
                t = int(tok[0][1:])
            elif c in "01xXzZ":
                for n in id_to_names.get(tok[0][1:], []):
                    changes[n].append((t, c))
            elif c in "bBrR":
                for n in id_to_names.get(tok[1], []):
                    changes[n].append((t, tok[0][1:]))
    return widths, changes, ts_ps


def value_at(chg, t):
    v = "x"
    for ct, cv in chg:
        if ct > t:
            break
        v = cv
    return v


def fmt_bus(v, width):
    if any(ch in v for ch in "xXzZ"):
        return "x"
    return format(int(v, 2), "x")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("png")
    ap.add_argument("--start", type=float, required=True, help="ns")
    ap.add_argument("--end", type=float, required=True, help="ns")
    ap.add_argument("--signals", nargs="+", required=True)
    ap.add_argument("--title", default="")
    a = ap.parse_args()

    widths, changes, ts_ps = parse_vcd(a.vcd, a.signals)
    t0, t1 = a.start * 1000 / ts_ps, a.end * 1000 / ts_ps

    fig, ax = plt.subplots(figsize=(14, 0.55 * len(a.signals) + 1.2))
    for row, name in enumerate(a.signals):
        if name not in widths:
            raise SystemExit("signal not found in VCD: " + name)
        y = len(a.signals) - 1 - row
        chg = [(t, v) for t, v in changes[name] if t0 < t < t1]
        pts = [(t0, value_at(changes[name], t0))] + chg + [(t1, None)]
        for (ta, va), (tb, _) in zip(pts, pts[1:]):
            xa, xb = ta * ts_ps / 1000, tb * ts_ps / 1000
            if widths[name] == 1:
                lvl = {"1": 0.8, "0": 0.1}.get(va, 0.45)
                ax.plot([xa, xb], [y + lvl] * 2, color="#1f6feb", lw=1.2)
                ax.plot([xb, xb], [y + 0.1, y + 0.8], color="#1f6feb", lw=0.6, alpha=0.5)
            else:
                ax.fill_between([xa, xb], y + 0.1, y + 0.8, color="#d8e6fb", ec="#1f6feb", lw=0.8)
                if xb - xa > (a.end - a.start) / 60:
                    ax.text((xa + xb) / 2, y + 0.45, fmt_bus(va, widths[name]),
                            ha="center", va="center", fontsize=7)
        ax.text(a.start - (a.end - a.start) * 0.005, y + 0.45, name.split(".")[-1],
                ha="right", va="center", fontsize=9, family="monospace")
    ax.set_xlim(a.start, a.end)
    ax.set_ylim(-0.2, len(a.signals))
    ax.set_yticks([])
    ax.set_xlabel("time (ns)")
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    if a.title:
        ax.set_title(a.title)
    fig.tight_layout()
    fig.savefig(a.png, dpi=130)


if __name__ == "__main__":
    main()
