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

Game data (`*.wad`) is downloaded by `scripts/get_freedoom.sh` and never
committed. Start with `docs/PLAN.md`.
