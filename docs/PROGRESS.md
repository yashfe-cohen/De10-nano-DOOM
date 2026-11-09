# Progress log

Update this file at the end of every task (see `docs/PLAN.md` section 0).

## Environment
- Quartus version: **Quartus Prime Lite 17.1** with Cyclone V device support
  (from the human, 2026-11-09). Verify against the project files at T1.9 (do
  not resave the `.qpf`/`.qsf` with a newer version).
- RISC-V GCC + flags that work: **xPack `riscv-none-elf-gcc` 15.2.0**
  (`-march=rv32im -mabi=ilp32`, multilib `rv32im/ilp32` present). Verified
  2026-11-09: a bare `-nostdlib` program and a newlib `--specs=nosys.specs`
  program both link at `0x4000_0000`; exact commands and the linker-script
  requirements are in `docs/tools.md`.
- ARM GCC (`arm-linux-gnueabihf-gcc`): not exercised yet, first used at T4.4.
- Icarus Verilog: tested with 13.0; Ubuntu 24.04 ships 12.0. `apt` and no-root
  install recipes are in `docs/tools.md`. The agent sandbox has no root, so
  there the package is unpacked into `/tmp` behind wrapper scripts — nothing in
  the repository depends on that. `sim/Makefile` only needs `iverilog` and
  `vvp` on `PATH` and prints `sim: 'iverilog' not found in PATH` otherwise.
- Board Linux image: (fill in at T4.4)
- Memory route used (A = F2SDRAM, B = F2H AXI): (fill in at T4.4)

## Decisions

- **Licence (2026-11-09, human):** our own RTL, C code and scripts are
  `GPL-2.0-or-later` (plan section 11.3 held that this is the human's call, and
  suggested exactly this). Full GPL-2.0 text in `LICENSE`; the "or later" part
  lives in the per-file `SPDX-License-Identifier: GPL-2.0-or-later` headers.
  Third-party parts keep their own licences: doomgeneric GPL-2.0, Freedoom data
  BSD-style (never committed), riscv-tests BSD-3-Clause. The firmware as a
  whole is therefore GPL-2.0.

## Task log

| Task | Date | Status | Notes |
|---|---|---|---|
| T0.0 | 2026-11-09 | done | Plan written (`docs/PLAN.md`). |
| T0.1 | 2026-11-09 | done | Repo skeleton: section-5 directory tree, `.gitignore`, `sim/Makefile` (zero-testbenches run exits 0), README rewritten in UTF-8. |
| T0.1a | 2026-11-09 | done | Licence decision from the human: `LICENSE` (GPL-2.0 text), SPDX headers, README licence section, `AGENTS.md` rule. A second commit under T0.1, because the licence answer arrived after T0.1 had closed. |
| T0.2 | T0.2 | 2026-11-09 | done | `scripts/check_tools.sh` (versions of iverilog/vvp/python3/RISC-V GCC/ARM GCC plus the `rv32im/ilp32` multilib, exit 1 when anything is missing) and `docs/tools.md` (apt, xPack and no-root Icarus install commands; verified `-march=rv32im -mabi=ilp32` bare and newlib links). |

## Plan deviations

(none yet)

## Measurements

| Date | Fmax clk_sys | ALMs | M10K | DSP | FPS (E1M1) | Notes |
|---|---|---|---|---|---|---|
