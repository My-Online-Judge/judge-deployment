"""Static PNG charts for the thesis (light, print). Categorical slots 1–4 of the validated palette in fixed order,
a marker shape per series (two slots are below 3:1 contrast on the surface, so identity never rests on colour),
one y-axis per chart, recessive grid, a legend whenever there are two or more series."""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
MARKERS = ["o", "s", "^", "D", "v", "P", "X", "*"]
INK, MUTED, GRID, SHADE, SURFACE = "#0b0b0b", "#52514e", "#e6e5e1", "#f0efec", "#fcfcfb"


def _style(ax, title, xlabel, ylabel):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, color=INK, fontsize=10, loc="left")
    ax.set_xlabel(xlabel, color=MUTED, fontsize=8)
    ax.set_ylabel(ylabel, color=MUTED, fontsize=8)
    ax.tick_params(colors=MUTED, labelsize=7)
    ax.grid(True, color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)


def timeseries_png(path, series, title, ylabel, t0, shade=(), ceiling=None):
    """ceiling: a measuring limit (the judge-latency histogram's top bucket) drawn as a dashed line."""
    fig, ax = plt.subplots(figsize=(8, 3.2), facecolor=SURFACE)
    if ceiling is not None:
        ax.axhline(ceiling, linestyle="--", color=MUTED, linewidth=0.8, label=f"histogram limit ({ceiling:g} s)")
    for k, (a, b) in enumerate(shade):
        ax.axvspan(a - t0, b - t0, color=SHADE, zorder=0, label="fault" if k == 0 else None)
    for k, (label, pts) in enumerate(sorted(series.items())[: len(SERIES)]):
        xs = [t - t0 for t, v in pts if v is not None]
        ys = [v for t, v in pts if v is not None]
        ax.plot(xs, ys, color=SERIES[k], linewidth=1.5, label=label if len(series) > 1 else None)  # one series: the title names it
    _style(ax, title, "seconds since the run started", ylabel)
    if len(series) > 1 or shade or ceiling is not None:
        ax.legend(fontsize=7, frameon=False)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def capacity_png(path, curves):
    """curves: {workers: [{"rate", "throughput", "p95"}]} — throughput and p95 as two charts side by side."""
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.6), facecolor=SURFACE)
    any_cut = False
    top = max((r["rate"] for rows in curves.values() for r in rows), default=1)
    axes[0].plot([0, top], [0, top], linestyle="--", color=MUTED, linewidth=0.8, label="verdicts = arrivals")
    for k, (workers, rows) in enumerate(sorted(curves.items())):
        name = f"{workers} worker" + ("s" if workers != 1 else "")
        for ax, key in zip(axes, ("throughput", "p95")):
            pts = sorted((r["rate"], r[key]) for r in rows if r.get(key) is not None)
            if not pts:
                continue
            ax.plot([p[0] for p in pts], [p[1] for p in pts], color=SERIES[k], marker=MARKERS[k], markersize=5,
                    linewidth=1.5, label=name)
            cut = [(r["rate"], r[key]) for r in rows if r.get(f"{key}_censored") and r.get(key) is not None]
            if cut:  # at or above the histogram limit: an open marker, the value is a lower bound
                ax.plot([p[0] for p in cut], [p[1] for p in cut], linestyle="none", marker=MARKERS[k], markersize=7,
                        markerfacecolor=SURFACE, markeredgecolor=SERIES[k])
                any_cut = True
            if key == "throughput":  # direct labels where the lines separate; the p95 lines meet at saturation
                ax.annotate(f"{workers}w", pts[-1], textcoords="offset points", xytext=(5, 0), fontsize=7, color=INK, va="center")
    _style(axes[0], "Judging throughput", "submissions arriving per second", "verdicts per second")
    _style(axes[1], "Judge latency p95 (submit → verdict)", "submissions arriving per second", "seconds")
    for ax in axes:
        ax.legend(fontsize=7, frameon=False)
    if any_cut:
        axes[1].annotate("open marker: at or above the histogram limit", (0.99, 0.02), xycoords="axes fraction",
                         ha="right", fontsize=7, color=MUTED)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
