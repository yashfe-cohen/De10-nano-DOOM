# De10-nano-DOOM

DOOM (open-source engine + Freedoom data) running on a home-made RV32IM CPU in
Verilog on the Terasic DE10-Nano, with HDMI video and audio.

- The game CPU is our own 5-stage RV32IM core, built from Verilog-2001.
- The Cyclone V's ARM (HPS) only helps: it boots Linux, loads the firmware and
  WAD into DDR, releases the RISC-V, and forwards USB keyboard events. It never
  runs game code.
- Video is a 320×200 indexed framebuffer scaled to 640×480 HDMI; sound effects
  are mixed in software and played over HDMI audio.

## Where things are

| Path | Contents |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | The master plan: architecture, memory maps, coding rules, task list. |
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | Task log, measurements, plan deviations. |
| [`AGENTS.md`](AGENTS.md) | Short working rules for whoever implements the plan. |
| `rtl/` | Synthesizable Verilog (CPU, memory system, video, audio, SoC, board top). |
| `sim/` | Icarus Verilog testbenches and models. |
| `sw/` | RISC-V firmware, boot ROM, tests, and the ARM-side helper `doomctl`. |
| `quartus/` | Quartus project, PLL IP and the HPS system. |
| `scripts/` | Tooling: Freedoom download, hex conversion, toolchain checks. |

## Checks

```sh
make -C sim test     # run every testbench; must print PASS for each
```

Game data (`*.wad`) is never committed: `scripts/get_freedoom.sh` downloads
Freedoom Phase 1 (Freedoom 0.13.0, a 28.8 MB `freedoom1.wad`) into the
git-ignored `data/` and prints its size and SHA-256. Start with
`docs/PLAN.md`.

## Licence

Our own RTL, C code and scripts are released under the GNU General Public
License, version 2 or (at your option) any later version
(`GPL-2.0-or-later`) — see [LICENSE](LICENSE). Every source file starts with an
`SPDX-License-Identifier: GPL-2.0-or-later` line.

Third-party parts keep their own licences:

| Part | Licence |
|---|---|
| [`doomgeneric`](https://github.com/ozkl/doomgeneric) engine (`sw/doom/` submodule) | GPL-2.0 |
| Freedoom Phase 1 game data (`freedoom1.wad`, downloaded, never committed) | BSD-style, see `COPYING.txt` in the Freedoom release |
| [`riscv-tests`](https://github.com/riscv-software-src/riscv-tests) (`sw/tests/isa/` submodule) | BSD-3-Clause |

The Doom firmware links `doomgeneric`, so the firmware image as a whole is
GPL-2.0; the complete corresponding source stays in this repository.
