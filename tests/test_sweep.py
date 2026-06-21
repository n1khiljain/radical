import os

from host.sweep import run_sweep, plot_sweep


def test_sweep_small_grid(tmp_path):
    out = tmp_path / "sweep.csv"
    rows = run_sweep(
        bers=[0.0, 0.2],
        n_samples=20,
        cycles_per_inf=2000,
        out_csv=str(out),
    )
    assert out.exists()
    assert len(rows) == 4                      # 2 BERs x {hardened, unhardened}

    by = {(r["ber"], r["hardened"]): r for r in rows}
    # Clean run: both perfect.
    assert by[(0.0, 0)]["accuracy"] == 1.0
    assert by[(0.0, 1)]["accuracy"] == 1.0
    # Under heavy faults: hardened beats unhardened.
    assert by[(0.2, 1)]["accuracy"] > by[(0.2, 0)]["accuracy"]
    # Hardening produces scrub corrections; unhardened does not.
    assert by[(0.2, 1)]["scrub_corrections"] > 0
    assert by[(0.2, 0)]["scrub_corrections"] == 0


def test_plot_sweep(tmp_path):
    csv_path = tmp_path / "sweep.csv"
    run_sweep(bers=[0.0, 0.1], n_samples=10, out_csv=str(csv_path))
    png = tmp_path / "curve.png"
    plot_sweep(csv_path=str(csv_path), out_png=str(png))
    assert png.exists()
    assert os.path.getsize(png) > 0
