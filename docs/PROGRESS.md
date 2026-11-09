# Progress log

Update this file at the end of every task (see `docs/PLAN.md` section 0).

## Environment
- Quartus version: (fill in at T0.1 — waiting for the human; only needed by the
  first Quartus task, T1.9)
- RISC-V GCC + flags that work: (fill in at T0.2)
- Board Linux image: (fill in at T4.4)
- Memory route used (A = F2SDRAM, B = F2H AXI): (fill in at T4.4)
- Icarus Verilog in the agent sandbox: not installed and not installable via
  `apt` (no root). For local runs the agent unpacks the Ubuntu `iverilog`
  package and calls it through wrappers; `sim/Makefile` itself only needs
  `iverilog`/`vvp` on `PATH`, so nothing in the repo depends on that setup.
  `make -C sim test` prints `sim: 'iverilog' not found in PATH` if it is missing.

## Task log

| Task | Date | Status | Notes |
|---|---|---|---|
| T0.0 | 2026-11-09 | done | Plan written (`docs/PLAN.md`). |
| T0.1 | 2026-11-09 | done | Repo skeleton: section-5 directory tree, `.gitignore`, `sim/Makefile` (zero-testbenches run exits 0), README rewritten in UTF-8. |

## Plan deviations

(none yet)

## Measurements

| Date | Fmax clk_sys | ALMs | M10K | DSP | FPS (E1M1) | Notes |
|---|---|---|---|---|---|---|
