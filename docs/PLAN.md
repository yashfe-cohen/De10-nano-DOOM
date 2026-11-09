# DE10-Nano DOOM — Master Work Plan

This document is the single source of truth for building this project.
It is written for an AI coding agent that will implement it task by task,
with a human who owns the physical board and runs Quartus.

Read sections 0–8 fully before starting any task. Then work through the
tasks in section 9 **in order**.

---

## 0. How to use this plan (rules for the AI agent)

1. Work on **one task at a time** (task IDs look like `T2.3`). Do not start a
   task until all its listed dependencies are marked done in `docs/PROGRESS.md`.
2. Every task ends with:
   - all its testbenches passing (`make -C sim test` prints only PASS lines),
   - `docs/PROGRESS.md` updated (task ID, date, what was done, anything odd),
   - one git commit named `T<id>: <short summary>`.
3. Tasks marked **[HW]** need the human. Prepare everything, write exact
   step-by-step instructions in `docs/hw_checkpoints/T<id>.md` (what to build,
   what to flash, what they should see, what to report back), then stop and
   ask the human to run it. Do not mark a [HW] task done without their report.
4. Never weaken or delete a test to make it pass. If a spec in this plan is
   wrong, write the problem in `docs/PROGRESS.md` under "Plan deviations",
   fix the plan text in the same commit, and explain why.
5. Keep code short and modular (see section 6). If a module grows past the
   limit, split it before continuing.
6. Facts marked **(verify)** in this plan come from memory, not from a
   datasheet. Before relying on them, confirm against the named source and
   record what you found in `docs/PROGRESS.md`.
7. Never commit game data (`*.wad`), Quartus output folders, or generated
   binaries. `.gitignore` must cover them.

---

## 1. Goal and fixed decisions

**Goal:** run the open-source DOOM engine on the DE10-Nano board, with the CPU
that executes the game built by us in Verilog inside the FPGA. Video and audio
go out through the board's HDMI port. Input is a USB keyboard.

Fixed decisions (do not change without the human's approval):

| Topic | Decision |
|---|---|
| HDL | Verilog-2001 only (no SystemVerilog). Must synthesize in Quartus Prime Lite and simulate in Icarus Verilog. |
| Game CPU | Our own RV32IM core, 5-stage pipeline, in the FPGA fabric. |
| Game code | `doomgeneric` (GPL-2.0, github.com/ozkl/doomgeneric) as a git submodule, plus our platform layer in C. |
| Game data | Freedoom Phase 1 (`freedoom1.wad`, BSD-licensed). Downloaded by script, never committed. |
| Main memory | The HPS DDR3 (1 GB). Linux is limited to the low 512 MB; the FPGA owns the top 512 MB. |
| Role of the ARM (HPS) | Helper only: boots a small Linux, loads firmware + WAD into DDR, releases the RISC-V from reset, forwards USB keyboard events, prints the RISC-V debug console. It never runs game code. |
| Video | 320×200 8-bit indexed framebuffer, doubled to 640×400, centred in 640×480@60 HDMI via the ADV7513 transmitter. |
| Audio | Sound effects mixed in software on the RISC-V, played by a Verilog I2S path into the ADV7513 (HDMI audio). Music via an OPL2-compatible FM synth written in Verilog (last phase). |
| Simulation | Icarus Verilog (`iverilog -g2005`). Verilator only optionally for lint. |
| Toolchain | `riscv-none-elf-gcc` (xPack) or any GCC with an `rv32im/ilp32` multilib + newlib or picolibc. |

---

## 2. System architecture

```
                         Cyclone V SoC (5CSEBA6U23I7)
 +----------------------------------------------------------------------------+
 |  HPS (ARM, Linux)                       |  FPGA fabric (our Verilog)        |
 |                                         |                                   |
 |  USB keyboard --> doomctl (C program)   |                                   |
 |                     |  LW H2F bridge    |   +-----------+                   |
 |                     +-------------------+-->| ctrl_regs |--cpu_rst, kbd FIFO |
 |                                         |   +-----------+  console FIFO     |
 |                                         |         |                         |
 |   DDR3 controller <--- F2SDRAM port ----+---+  +--v-------------------+     |
 |   (1 GB, top 512 MB = FPGA)             |   |  |  RV32IM core (5-stg) |     |
 |                                         |   |  +--+--------------+----+     |
 |                                         |   |     | I$           | D$/MMIO  |
 |                                         |   |  +--v--+       +---v---+      |
 |                                         |   +--| arb |<------| dcache|      |
 |                                         |      +-----+       +-------+      |
 |                                         |                        | MMIO bus |
 |                                         |   +--------+ +-------+ +-------+  |
 |                                         |   | timer  | | video | | audio |  |
 |                                         |   +--------+ +---+---+ +---+---+  |
 |                                         |                  |  HDMI  |  I2S   |
 +-----------------------------------------+------------------+--------+-------+
                                                            ADV7513 --> HDMI TV
```

Data flow at run time:
1. Linux boots on the ARM. U-Boot has already loaded our FPGA bitstream and
   enabled the FPGA-to-SDRAM bridge.
2. `doomctl` writes `doom.bin` and `freedoom1.wad` into the FPGA half of DDR,
   writes a boot-info block, then clears the RISC-V reset bit.
3. The RISC-V runs the boot ROM, which jumps to the firmware in DDR.
4. The firmware (doomgeneric + our platform layer) renders each frame into a
   buffer in DDR, then copies it into the FPGA framebuffer over MMIO.
5. The video block scans the framebuffer through the palette RAM to the ADV7513.
6. `doomctl` pushes key events into a FIFO the RISC-V reads; the RISC-V's
   `printf` output goes into a FIFO that `doomctl` prints.

---

## 3. Clocks and resets

| Clock | Freq | Source | Used by |
|---|---|---|---|
| `clk_sys` | 50 MHz first, target 100 MHz (T10) | PLL0 from `FPGA_CLK1_50` | CPU, caches, MMIO, ctrl_regs, F2SDRAM port, LW bridge |
| `clk_pix` | 25.0 MHz | PLL0 | video timing, framebuffer read side, palette read |
| `clk_pix_out` | 25.0 MHz, 180° | PLL0 | drives `HDMI_TX_CLK` pin only |
| `clk_aud` | 12.288 MHz | PLL1 (fractional) | I2S, audio rate converter, OPL synth |

Rules:
- Every clock domain has its own reset synchronizer (`reset_sync.v`):
  async assert, sync deassert, active-high `rst` output.
- Global reset source: PLL not locked OR `KEY[0]` pressed.
- The CPU has an extra reset: `cpu_rst = rst_sys | ctrl_cpu_reset_bit`.
  The bit defaults to 1 (held) after FPGA reset.
- Only these crossings exist, and each uses a listed primitive:
  - sys → pix: framebuffer and palette (dual-clock RAMs), front-buffer select (2-FF sync of a level).
  - pix → sys: vblank level and frame toggle (2-FF sync).
  - sys → aud: audio sample FIFO and OPL register-write FIFO (`fifo_async.v`).
  - aud → sys: FIFO fill levels come from the async FIFO's own gray-coded pointers.
- Write an `.sdc` that declares all clocks and sets the clock groups as
  asynchronous to each other (`set_clock_groups -asynchronous`).

---

## 4. Address maps

### 4.1 RISC-V address map (what the CPU sees)

| Range | Size | Region | Cached | Notes |
|---|---|---|---|---|
| `0x0000_0000`–`0x0000_0FFF` | 4 KB | Boot ROM | no | Reset vector `0x0000_0000`. Readable by I-side and D-side. |
| `0x1000_0000`–`0x1000_0FFF` | 4 KB | MMIO registers | no | See 4.2. |
| `0x1100_0000`–`0x1100_F9FF` | 64000 B | Framebuffer 0 | no | Write-only. Word writes (byte enables honoured). |
| `0x1101_0000`–`0x1101_F9FF` | 64000 B | Framebuffer 1 | no | Write-only. |
| `0x4000_0000`–`0x4FFF_FFFF` | 256 MB | DDR window | yes | Maps to physical DDR `0x2000_0000 + (addr - 0x4000_0000)`. |

Any other address: loads return 0, stores are ignored, and the
`DBG_STATUS.bus_err` sticky bit is set (helps catch wild pointers).

Routing rule (keep the decoder trivial): `addr[31:28]==4'h4` → D-cache;
`addr[31:28]==4'h1` → MMIO bus (`addr[24]` selects registers vs framebuffer);
`addr[31:28]==4'h0` → boot ROM.

DDR window layout (CPU addresses):

| Address | Contents |
|---|---|
| `0x4000_0000` | Firmware image (`doom.bin`): `.text`, `.rodata`, `.data`, then `.bss`. Entry point = `0x4000_0000`. Max 8 MB. |
| `0x4080_0000`–`0x47EF_FFFF` | Heap (grows up, `_sbrk`) |
| `0x47F0_0000`–`0x47FF_FFFF` | Stack (1 MB, grows down from `0x4800_0000`) |
| `0x4800_0000` | WAD image, raw bytes (max 64 MB) |
| `0x4FFF_F000` | Boot-info block (see below) |

Boot-info block (little-endian words, written by `doomctl`):

| Offset | Field |
|---|---|
| `+0x00` | magic `0x544F4F42` ("BOOT") |
| `+0x04` | entry point (normally `0x4000_0000`) |
| `+0x08` | WAD address (normally `0x4800_0000`) |
| `+0x0C` | WAD size in bytes |
| `+0x10` | WAD file name, NUL-terminated, max 32 bytes (e.g. `freedoom1.wad`) |

### 4.2 MMIO registers (base `0x1000_0000`, all 32-bit, word access only)

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x000` | SYS_ID | R | `0x52563332` ("RV32") |
| `0x004` | SYS_LED | R/W | bits [7:0] drive `LED[7:0]` |
| `0x008` | SYS_INPUT | R | `{26'b0, SW[3:0], KEY[1:0]}`, synchronized |
| `0x00C` | SYS_EXIT | W | Writing any value halts the CPU with cause EXIT and stores the value in `DBG_EXIT`. Used by tests (`1` = pass). |
| `0x100` | TIMER_LO | R | Microsecond counter, low 32 bits |
| `0x104` | TIMER_HI | R | High 32 bits (software reads HI, LO, HI and retries on change) |
| `0x200` | CON_TX | W | Push byte `[7:0]` to console FIFO (256 deep). If full: byte dropped, `CON_STAT.ovf` sticky set. |
| `0x204` | CON_STAT | R | bit0 = full, bit1 = ovf (cleared on read) |
| `0x300` | KBD_DATA | R | Pop: `{valid[31], 22'b0, pressed[8], code[7:0]}`. `code` = Linux evdev key code (low 8 bits). Reading when empty returns `valid=0`. |
| `0x400` | VID_CTRL | R/W | bit0 = requested front buffer. Takes effect at next vblank start. |
| `0x404` | VID_STAT | R | bit0 = displayed front buffer, bit1 = swap pending, bit2 = in vblank, [31:16] = frame counter |
| `0x408` | VID_PAL | W | `{index[31:24], r[23:16], g[15:8], b[7:0]}` writes one palette entry |
| `0x500` | AUD_DATA | W | Push stereo sample `{left[31:16], right[15:0]}`, signed 16-bit, at 11025 Hz |
| `0x504` | AUD_STAT | R | [11:0] = FIFO fill level (in samples), bit31 = underrun sticky (cleared on read) |
| `0x508` | AUD_CTRL | R/W | bit0 = enable, [15:8] = master SFX volume (0–255), [23:16] = music volume |
| `0x600` | OPL_ADDR | W | OPL2 register address (8 bits) |
| `0x604` | OPL_DATA | W | Writes data to the register selected by OPL_ADDR |
| `0x608` | OPL_STAT | R | bit0 = write FIFO full |

### 4.3 ARM-side registers (LW H2F bridge, ARM physical base `0xFF20_0000`)

Implemented by `ctrl_regs.v` in the `clk_sys` domain (the LW bridge is clocked
by `clk_sys`, so no CDC is needed).

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | ID | R | `0x444F4F4D` ("DOOM") |
| `0x04` | CTRL | R/W | bit0 = cpu_reset (1 = held, default 1) |
| `0x08` | KBD_PUSH | W | `{pressed[8], code[7:0]}` pushed to the keyboard FIFO (16 deep) |
| `0x0C` | CON_POP | R | Pop: `{valid[31], 23'b0, byte[7:0]}` |
| `0x10` | DBG_STATUS | R | bit0 = halted, [7:4] = halt cause, bit8 = bus_err sticky |
| `0x14` | DBG_PC | R | PC of the last retired instruction |
| `0x18` | DBG_ADDR | R | Faulting address for misaligned/bus errors |
| `0x1C` | DBG_EXIT | R | Value written to `SYS_EXIT` |
| `0x20` | PERF_CYC | R | CPU cycle counter (low 32) |
| `0x24` | PERF_INSTR | R | Retired instruction counter (low 32) |
| `0x28` | VID_FRAMES | R | Frame counter |

Halt causes: 1 = EXIT, 2 = ECALL/EBREAK, 3 = illegal instruction,
4 = misaligned fetch, 5 = misaligned load, 6 = misaligned store.

### 4.4 Physical DDR (ARM view)

| Physical range | Owner |
|---|---|
| `0x0000_0000`–`0x1FFF_FFFF` | Linux (`mem=512M` on the kernel command line) |
| `0x2000_0000`–`0x2FFF_FFFF` | RISC-V DDR window (CPU `0x4000_0000`–`0x4FFF_FFFF`) |
| `0x3000_0000`–`0x3FFF_FFFF` | Unused / spare |

---

## 5. Repository layout

```
AGENTS.md                 short rules for agents (points here)
docs/PLAN.md              this file
docs/PROGRESS.md          task log + plan deviations
docs/hw_checkpoints/      instructions for the human per [HW] task
rtl/common/               reset_sync, sync_2ff, fifo_sync, fifo_async, ram_* , delay_line
rtl/cpu/                  rv_defs.vh + core modules (rv_*.v)
rtl/mem/                  icache, dcache, line_master, mem_arb, boot_rom, bus_decode
rtl/video/                video_timing, fb_ram, palette_ram, video_out, video_regs
rtl/hdmi/                 i2c_master, adv7513_rom, adv7513_init
rtl/audio/                i2s_tx, aud_rate, audio_regs, opl/*
rtl/io/                   sys_regs, timer, console, kbd_fifo, ctrl_regs, mmio_mux
rtl/soc/                  soc_top.v (everything except board pins and HPS)
rtl/board/                de10_top.v (pins, PLLs, HPS instance)
sim/                      Makefile, tb_*.v, models/ (mem_model, avalon_ddr_model, adv7513_i2c_model)
quartus/                  de10_nano.qpf/.qsf/.sdc, ip/ (PLLs), qsys/soc_hps.qsys
sw/common/                mmio.h, crt0.S, link.ld, syscalls.c, Makefile.inc
sw/boot/                  boot ROM source (start.S) -> boot_rom.hex
sw/tests/isa/             riscv-tests env header + list of tests
sw/tests/*/               hello, memtest, fbtest, kbdtest, audiotest, opltest
sw/doom/                  doomgeneric (submodule), patches/, dg_de10.c, i_de10sound.c, i_de10music.c, Makefile
sw/arm/                   doomctl.c, Makefile (cross-compiled for arm-linux-gnueabihf)
scripts/                  get_freedoom.sh, bin2hex.py, gen_opl_tables.py, build_sd.md
```

---

## 6. Verilog coding rules

These rules exist to keep every module short, readable and easy to test.

1. **One module per file**, file name = module name. Module names are
   lower_snake_case with a prefix per area: `rv_` (CPU), `vid_`/`video_`,
   `aud_`, `opl_`, etc.
2. **Size limit:** aim for ≤ 120 lines per module, hard limit 200 lines
   (excluding the header comment). Split by function when bigger.
3. Every file starts with `` `default_nettype none `` and ends with
   `` `default_nettype wire ``.
4. Header comment (3–8 lines): what it does, latency in cycles, clock domain,
   and anything surprising. No long essays.
5. Clock is always `clk`, reset always `rst` (active high, synchronous inside
   the module). Multi-clock modules use `clk_a`/`clk_b` style names with
   matching `rst_a`/`rst_b`.
6. Handshakes: `valid`/`ready` for streams; `req`/`ack` for memory ports
   (defined in 9.5). Signals are active high unless the pin is active low
   (then suffix `_n`).
7. Two process styles only: `always @(posedge clk)` for registers and
   `always @(*)` for combinational logic with a default assignment for every
   output at the top (no latches).
8. No `initial` blocks in synthesizable code, except `$readmemh` in ROM/RAM
   files (Quartus supports this for inference).
9. RAMs are **inferred** from the templates in `rtl/common/ram_*.v`. No
   vendor RAM IP. The only vendor IP allowed: the two PLLs and the HPS
   (Platform Designer).
10. Constants in `localparam` or in a shared `.vh` include file. No magic
    numbers in logic.
11. Parameterize widths and depths; give parameters sensible defaults.
12. No `#delays` in RTL. Testbenches may use them.
13. Lint clean: `iverilog -g2005 -Wall` must give no warnings on RTL files.
    Optionally also `verilator --lint-only -Wall`.

Testbench rules:
- `sim/tb_<module>.v` for every RTL module with logic (pure wiring tops are
  tested through the parent).
- Self-checking: compare against expected values, count errors, print exactly
  one final line `PASS tb_<name>` or `FAIL tb_<name> (<n> errors)`, then `$finish`.
- Include a timeout that prints FAIL.
- Optional VCD dump controlled by `+vcd` plusarg.
- `sim/Makefile`:
  - `make -C sim T=<name>` runs one testbench,
  - `make -C sim test` runs all and exits non-zero if any FAIL or missing PASS.

---

## 7. Test strategy (levels)

| Level | Tool | What it proves |
|---|---|---|
| L1 Unit | Icarus, `tb_<module>.v` | each module meets its spec |
| L2 CPU ISA | Icarus + `riscv-tests` (rv32ui, rv32um) via custom env | the core executes RV32IM correctly |
| L3 SoC sim | Icarus, full `soc_top` + `avalon_ddr_model` (random latency) + small C programs | caches, MMIO and boot path work together |
| L4 Host | gcc on the PC, platform layer compiled with a fake MMIO | WAD-in-memory file system and Doom glue logic are correct before hardware |
| L5 Board | the human, via `docs/hw_checkpoints/` | real hardware works |

Doom itself is far too slow to run in Icarus. Never try. L3 programs must
finish within ~2 million cycles.

---

## 8. Human ↔ AI workflow

- The AI writes code, tests, scripts and instructions. It runs Icarus and the
  RISC-V GCC locally.
- The human runs Quartus Prime Lite (record the exact version in
  `docs/PROGRESS.md` at T0.1), programs the board, prepares the SD card, and
  reports back.
- A checkpoint report from the human should contain: compile result
  (errors/warnings count, Fmax per clock from the Timing Analyzer), resource
  usage (ALMs, M10K blocks, DSPs), and what was seen on the screen / console.
- If Quartus reports an error, the human pastes the message; the AI fixes the
  code and re-issues the checkpoint.

---

## 9. Phases and tasks

Format of each task: **Goal**, **Files**, **Spec**, **Tests**, **Done when**.

### Phase 0 — Setup

**T0.1 Repo skeleton**
- Goal: directories from section 5, `.gitignore`, `sim/Makefile`, `AGENTS.md`, `docs/PROGRESS.md`.
- `.gitignore`: `*.wad`, `*.bin`, `*.elf`, `*.hex` (except `sw/boot/boot_rom.hex` if committed on purpose), `*.vcd`, `sim/build/`, `quartus/db/`, `quartus/incremental_db/`, `quartus/output_files/`, `quartus/qsys/soc_hps/`, `*.rbf`, `*.sof`.
- Convert `README.md` from UTF-16 to UTF-8 and add a short project description and a link to this plan.
- Done when: `make -C sim test` runs (with zero testbenches) and exits 0.

**T0.2 Toolchain check script**
- `scripts/check_tools.sh`: prints versions of `iverilog`, `vvp`, `riscv-none-elf-gcc` (or the chosen GCC), `python3`, `arm-linux-gnueabihf-gcc`; fails clearly if missing.
- Document install commands in `docs/tools.md` (apt packages for Icarus/ARM GCC; xPack download for RISC-V GCC).
- Confirm the RISC-V GCC can link a bare program with `-march=rv32im -mabi=ilp32` and newlib/picolibc. Record the exact flags that work.

**T0.3 Freedoom fetch script**
- `scripts/get_freedoom.sh`: downloads the latest Freedoom release zip from the official GitHub releases page into `data/` (git-ignored), unzips, checks `freedoom1.wad` exists, prints its size and SHA-256.

### Phase 1 — Common building blocks (`rtl/common/`)

Each item gets its own testbench.

| Task | Module | Spec summary |
|---|---|---|
| T1.1 | `reset_sync` | async assert, 2-FF sync deassert; param `STAGES=2` |
| T1.2 | `sync_2ff` | param `W`; level synchronizer (only for slow levels / toggles) |
| T1.3 | `delay_line` | param `W`, `N`; N-cycle register delay (N may be 0) |
| T1.4 | `fifo_sync` | params `W`, `DEPTH_LOG2`; `wr_en/din/full`, `rd_en/dout/empty`, `level`; first-word-fall-through output |
| T1.5 | `fifo_async` | gray-code pointers, 2-FF sync; same ports plus `wr_level` (write side) and `rd_level` (read side); FWFT |
| T1.6 | `ram_sdp` | simple dual-port, one clock: write port (addr, data, byte enable), read port (addr → data next cycle). Byte enables via `W/8` lanes. Old data on read-during-write. |
| T1.7 | `ram_sdp_dc` | same as `ram_sdp` but separate write clock and read clock |
| T1.8 | `rom_sync` | param `INIT_FILE`; `$readmemh`; registered output; two read ports option (`DUAL=1`) |

`tb_fifo_async` must test random write/read rates with unrelated clock
periods (e.g. 10 ns and 37 ns) and check data order and no loss.

**T1.9 Quartus RAM inference check [HW]**
- Small throwaway top that instantiates each RAM template at the sizes used
  later (32×16K with byte enables; 24×256 dual-clock). The human compiles it
  and confirms in the fitter report that they map to M10K blocks, not logic.

### Phase 2 — HDMI color bars (first board milestone, no HPS needed)

**T2.1 `video_timing`** (clk_pix)
- 640×480@60: H total 800 (visible 640, front 16, sync 96, back 48),
  V total 525 (visible 480, front 10, sync 2, back 33). Sync pulses active low.
- Outputs: `x[9:0]`, `y[9:0]`, `de`, `hs`, `vs`, `vblank_start` (1-cycle pulse
  at the first non-visible line), `line_start` pulse.
- Test: count exact cycles per line/frame, sync widths, `de` count = 640×480.

**T2.2 `i2c_master`** (clk_sys)
- Write-only byte transactions: `start`, `dev_addr[6:0]`, `reg`, `data`,
  `busy`, `ack_err`. ~100 kHz SCL from a parameter `CLK_HZ`. Open-drain:
  `scl_oe`, `sda_oe` outputs (pin driven low when oe=1, else `'bz`), and
  `sda_in` for ACK sampling.
- Test with `sim/models/i2c_slave_model.v` that ACKs address `0x39` and
  records written register/value pairs.

**T2.3 `adv7513_rom` + `adv7513_init`**
- ROM of `{reg, value}` pairs, terminated by `{8'hFF, 8'hFF}`. Init FSM walks
  the ROM through `i2c_master` (7-bit address `0x39`).
- Re-run the full init when the transmitter's interrupt pin (`HDMI_TX_INT`,
  active low) goes low after being high (hot-plug), with a ~10 ms debounce.
- Output `init_done` (drive an LED).
- Starting register list (verify against the ADV7513 Programming Guide and
  the Terasic DE10-Nano HDMI demo; fix and document any differences):

  | Reg | Value | Meaning (verify) |
  |---|---|---|
  | 0x41 | 0x10 | power up |
  | 0x98 | 0x03 | required fixed value |
  | 0x9A | 0xE0 | required fixed value |
  | 0x9C | 0x30 | required fixed value |
  | 0x9D | 0x61 | required fixed value |
  | 0xA2 | 0xA4 | required fixed value |
  | 0xA3 | 0xA4 | required fixed value |
  | 0xE0 | 0xD0 | required fixed value |
  | 0xF9 | 0x00 | required fixed value |
  | 0x15 | 0x20 | input ID: 24-bit RGB 4:4:4 separate syncs; audio Fs 48 kHz in [7:4] |
  | 0x16 | 0x30 | output 4:4:4, 8-bit, RGB |
  | 0x17 | 0x02 | 4:3 aspect, sync polarity from input |
  | 0x18 | 0x46 | colour space converter off |
  | 0xAF | 0x06 | HDMI mode (needed for audio) |
  | 0xD6 | 0xC0 | treat hot-plug as always present |
  | 0x01–0x03 | 0x00,0x18,0x00 | audio N = 6144 (48 kHz) |
  | 0x0A | 0x01 | audio select I2S, auto CTS |
  | 0x0C | 0x04 | I2S0 enabled, standard I2S format |

- Test: run with the I2C slave model, check every pair arrives in order.

**T2.4 `test_pattern`** (clk_pix): 8 vertical colour bars + a 1-pixel white
border around 640×480 (to check nothing is cropped).

**T2.5 Quartus project + `de10_top` (video only) [HW]**
- Quartus project for `5CSEBA6U23I7`. Take pin assignments from Terasic's
  DE10-Nano System Builder / GHRD `.qsf` (do not type pin numbers from
  memory). Pins needed now: `FPGA_CLK1_50`, `KEY[1:0]`, `SW[3:0]`, `LED[7:0]`,
  all `HDMI_*`.
- PLL0 via the Quartus PLL IP (50 MHz → 50 MHz `clk_sys`, 25 MHz `clk_pix`,
  25 MHz 180° `clk_pix_out`).
- `HDMI_TX_D[23:16]=R`, `[15:8]=G`, `[7:0]=B` (verify bit order in the manual).
- I2C pins are bidirectional open-drain.
- Human checks: colour bars with full white border on the TV; LED for
  `init_done` on; unplug/replug HDMI recovers the picture.

### Phase 3 — Framebuffer and palette

**T3.1 `fb_ram`**: wraps `ram_sdp_dc`, 32 bits × 32768 words (2 buffers ×
16384 words; only 16000 used per buffer). Write side (clk_sys): word address
`{buf, word[13:0]}`, 4 byte enables. Read side (clk_pix): word address → data
next cycle.

**T3.2 `palette_ram`**: 24 × 256, dual clock, write from clk_sys, read from
clk_pix (1-cycle latency).

**T3.3 `video_out`** (clk_pix)
- Active Doom area: screen lines 40–439, all 640 columns. Source pixel
  `xs = x>>1` (0–319), `ys = (y-40)>>1` (0–199).
- Never multiply: keep a `row_base` register (+320 every second active line,
  reset at frame start). Pixel index `p = row_base + xs`; word = `p>>2`,
  byte lane = `p[1:0]` (lane 0 = bits [7:0], little-endian).
- Pipeline: timing → fb read (1) → byte select + palette read (1) → output
  register (1). Delay `de/hs/vs` with `delay_line` to match. Outside the
  active area output black.
- Front buffer select: input `front_buf` (already synchronized), latched at
  `vblank_start`. Outputs `shown_buf`, `frame_toggle` (toggles at
  `vblank_start`), `in_vblank`.
- Test: preload framebuffer and palette with known patterns; capture one full
  frame of RGB output in the testbench and compare every pixel against a
  reference computed in the testbench; check buffer switch happens only at
  vblank.

**T3.4 `video_regs`** (clk_sys): MMIO slave for `VID_CTRL/VID_STAT/VID_PAL`
plus the framebuffer write window. Synchronizes `shown_buf`, `in_vblank`,
`frame_toggle` from clk_pix; counts frames; `swap_pending = (req != shown)`.

**T3.5 Pattern writer + board test [HW]**
- Temporary FSM `fb_demo_writer` in clk_sys that fills buffer 0 with a test
  image (e.g. `pixel = x ^ y`) and loads a grey-scale + rainbow palette.
- Human checks: the image is centred, has black bars top and bottom, pixels
  are square, no tearing or noise.

### Phase 4 — HPS, DDR access and ARM control

This phase is the riskiest platform work. Do it before the CPU so the memory
path is proven with simple logic.

**T4.1 Platform Designer system (`quartus/qsys/soc_hps.qsys`)**
- Start from Terasic's DE10-Nano GHRD HPS settings (DDR3 timing, HPS I/O for
  USB, Ethernet, SD, UART). Keep those; remove everything else.
- Enable the **H2F lightweight bridge**; connect it to an exported
  Avalon-MM Pipeline Bridge so the FPGA sees an Avalon-MM master
  (`lw_*` signals, 32-bit data, byte address) clocked by `clk_sys`.
- Memory path, primary route (A): enable **FPGA-to-SDRAM port 0** as
  Avalon-MM, 64-bit, and export it. Clock it from `clk_sys`.
- Fallback route (B), only if A fails at T4.4: use the **FPGA-to-HPS AXI
  bridge** (64-bit) behind an exported Avalon-MM Pipeline Bridge slave.
- Either way, the FPGA logic sees a 64-bit Avalon-MM slave port named
  `ddr_*`: `address`, `burstcount` (max 4 needed), `read`, `write`,
  `writedata`, `byteenable`, `readdata`, `readdatavalid`, `waitrequest`.
  Record whether `address` is in bytes or in 64-bit words (verify in the
  generated HDL) and set `line_master`'s `ADDR_IS_BYTE` parameter.

**T4.2 `line_master`** (clk_sys) — the only module that talks to `ddr_*`
- Command port: `cmd_valid`, `cmd_ready`, `cmd_write`, `cmd_addr[31:5]`
  (32-byte line address, **physical**), `wline[255:0]`; response `rsp_valid`,
  `rline[255:0]`.
- Read: one burst of 4 beats (64-bit each); beat 0 = bytes 0–7 of the line.
- Write: one burst of 4 beats, all byte enables set.
- Must handle `waitrequest` on every beat and `readdatavalid` gaps.
- Test with `sim/models/avalon_ddr_model.v`: a sparse memory model with
  random `waitrequest` and random read latency (2–30 cycles), checks Avalon
  protocol rules (signals held stable while `waitrequest`).

**T4.3 `ddr_memtest`** (temporary, clk_sys)
- Started/stopped by a bit in `ctrl_regs` (temporary register `0x40`), writes
  a pseudo-random pattern (LFSR seeded from address) over 16 MB at physical
  `0x2000_0000`, reads it back, reports pass/fail and error count in
  registers `0x44`/`0x48`.

**T4.4 `ctrl_regs` + `de10_top` with HPS [HW]**
- `ctrl_regs` implements section 4.3 (only ID, CTRL and memtest registers
  for now). Avalon-MM slave on the LW bridge.
- SD card: Terasic's DE10-Nano Linux SD image (LXDE or console). Write
  `scripts/build_sd.md` covering:
  - convert `.sof` → `.rbf` (`quartus_cpf`, compressed),
  - put `soc_system.rbf` on the FAT partition,
  - U-Boot: load the rbf, `fpga load`, then `bridge enable` **before** Linux
    boots (this releases the FPGA-to-SDRAM port reset),
  - kernel argument `mem=512M`.
- If the stock preloader does not configure our F2SDRAM port (memtest fails,
  hangs or reads zeros): try regenerating the preloader from our handoff
  files with the SoC EDS `bsp-editor`; if still failing, switch to route B.
  Record exactly what worked in `docs/PROGRESS.md`. Useful registers
  (verify in the Cyclone V HPS TRM, SDRAM controller chapter):
  `fpgaportrst` at `0xFFC25080`, `staticcfg` at `0xFFC2505C`.
- Human checks, from the ARM shell (`devmem` or a tiny C program):
  ID reads `0x444F4F4D`; memtest passes; ARM reads the same pattern from
  `/dev/mem` at `0x2000_0000` (proves both sides see the same DDR).

**T4.5 `doomctl` v0 (ARM)**
- `sw/arm/doomctl.c`, cross-compiled with `arm-linux-gnueabihf-gcc -O2 -static`.
- `mmap` `/dev/mem` with `O_SYNC` for the LW bridge (`0xFF200000`, 4 KB) and
  the DDR window (`0x20000000`, 256 MB).
- Commands: `doomctl id`, `doomctl memtest`, `doomctl peek <addr>`,
  `doomctl poke <addr> <val>`. Later tasks add more.

### Phase 5 — RV32IM core (simulation only)

**Core interfaces (`rv_core`)**

Instruction port:
- `i_req` + `i_addr[31:0]`: presented **combinationally** in cycle *t*
  (from the next-PC mux), so a synchronous RAM can return data at the edge.
- `i_ack` + `i_data[31:0]`: valid in cycle *t+1* or later. While `i_ack=0`
  the core is stalled and keeps presenting the same address.

Data port (same timing rule, address comes from the EX-stage adder):
- `d_req`, `d_we`, `d_be[3:0]`, `d_addr[31:0]`, `d_wdata[31:0]`
- `d_ack`, `d_rdata[31:0]`

Debug outputs: `halted`, `halt_cause[3:0]`, `dbg_pc`, `dbg_addr`,
`retire` (1-cycle pulse per retired instruction).

**Pipeline spec**
- Stages IF, ID, EX, MEM, WB. Reset PC = `0x0000_0000`.
- Register file: 32×32 in flip-flops (not M10K), 2 read ports, write in WB,
  write-to-read bypass inside the file. `x0` always 0.
- Forwarding into EX from EX/MEM and MEM/WB.
- Load-use: 1-cycle stall (bubble into EX).
- Branches and jumps resolved in EX; on redirect flush IF/ID and ID/EX
  (2-cycle penalty). Static not-taken (branch prediction comes in T10).
- Any `i_ack=0` or `d_ack=0` (when a memory op is in MEM) freezes the
  **whole** pipeline. Simple and safe. Do not optimise this yet.
- MUL/MULH/MULHSU/MULHU: 2-cycle unit built for DSP blocks (33×33 signed
  multiply, registered). Stalls the pipeline 1 extra cycle.
- DIV/DIVU/REM/REMU: iterative radix-2, ~33 cycles, freezes the pipeline.
  Must follow the RISC-V spec for divide-by-zero and overflow.
- CSRs: only `cycle`, `cycleh`, `instret`, `instreth` (read-only via
  `csrrs rd, csr, x0`). Other CSR instructions halt with cause 3.
- FENCE: no-op. FENCE.I: no-op (we never modify code at run time).
- ECALL/EBREAK → halt cause 2. Illegal opcode → cause 3.
- Misaligned fetch/load/store → halt with cause 4/5/6 and `dbg_addr`.
  (No traps or interrupts in this design.)
- `halted` stops the pipeline permanently until reset.

**Module split (each with its own testbench)**

| Task | File | Content |
|---|---|---|
| T5.1 | `rv_defs.vh` | opcode, funct3/funct7, ALU op codes, halt causes |
| T5.2 | `rv_regfile.v` | 32×32 FF register file with bypass |
| T5.3 | `rv_decode.v` | instruction → control bundle (alu_op, src selects, imm type, mem op, wb select, is_branch, is_jal, is_jalr, is_mul, is_div, is_csr, illegal) |
| T5.4 | `rv_imm.v` | I/S/B/U/J immediate generator |
| T5.5 | `rv_alu.v` | ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND (+ LUI/AUIPC via src select) |
| T5.6 | `rv_branch.v` | BEQ/BNE/BLT/BGE/BLTU/BGEU compare |
| T5.7 | `rv_mul.v` | 2-cycle multiplier, all four variants |
| T5.8 | `rv_div.v` | iterative divider, all four variants, edge cases |
| T5.9 | `rv_lsu.v` | store byte-enable/data alignment, load extract + sign extend, misalignment detect |
| T5.10 | `rv_hazard.v` | load-use detect, forwarding selects, freeze/flush outputs |
| T5.11 | `rv_csr.v` | cycle/instret counters |
| T5.12 | `rv_core.v` | pipeline registers + wiring of the above (may be split into `rv_if.v`, `rv_id.v`, `rv_ex.v`, `rv_mem.v`, `rv_wb.v` to stay under 200 lines each) |

Unit tests for `rv_alu`, `rv_mul`, `rv_div` compare against a Verilog
reference expression over ≥ 10 000 random inputs plus all edge cases
(0, 1, −1, `0x80000000`, `0x7FFFFFFF`).

**T5.13 `sim/models/mem_model.v`** — ideal memory with the core's port timing
(1-cycle ack), plus an option to insert random ack delays on both ports.
Loads a hex file at `0x0000_0000`. A store to `0x1000_000C` (`SYS_EXIT`) ends
the simulation: value 1 = PASS, anything else = FAIL with test number
`value>>1`.

**T5.14 ISA compliance with riscv-tests**
- Add `riscv-tests` as a git submodule (only `isa/` sources are used).
- Write our own env header `sw/tests/isa/env/riscv_test.h` + `link.ld`:
  `RVTEST_CODE_BEGIN` = plain start at `0x0`; `RVTEST_PASS` = store 1 to
  `SYS_EXIT`; `RVTEST_FAIL` = store `(TESTNUM<<1)|1` to `SYS_EXIT`; no CSR
  setup. Data section placed after code.
- Run all `rv32ui-p-*` and `rv32um-p-*` tests except `fence_i` and
  `ma_data`, with random ack delays on and off.
- `make -C sim isa` builds and runs them all and prints a summary.
- Done when: every test passes in both delay modes.

**T5.15 C smoke test in sim**
- `sw/tests/sim_c/`: small C program (crt0 + main) that computes a CRC,
  sorts an array, uses multiply/divide, and writes the result to `SYS_EXIT`.
  Compiled with `-O2`. Passes on the core with `mem_model`.

### Phase 6 — Caches and memory system (simulation)

**T6.1 `icache`**
- Direct-mapped, 8 KB (parameter), 32-byte lines (8 words).
- Data RAM: `ram_sdp` 32-bit × 2048. Tag RAM: `ram_sdp` with
  `{valid, tag}` per line.
- Address from the core goes straight into both RAM read ports
  (combinational `i_addr`). Next cycle: compare tag with the registered
  address → `i_ack` on hit.
- Miss: request a line from `line_master` (through the arbiter), write 8
  words into the data RAM, write the tag, then re-read and ack.
- Translates CPU address to physical: `phys = addr - 0x4000_0000 + 0x2000_0000`.
- Reset: invalidate all lines (walk the tag RAM, one line per cycle; hold
  `i_ack=0` while doing it).

**T6.2 `dcache`**
- Direct-mapped, 16 KB (parameter), 32-byte lines, write-back,
  write-allocate.
- Tag RAM entry `{valid, dirty, tag}`.
- Load hit: 1 cycle (same scheme as I-cache).
- Store hit: 2 cycles (cycle 1 tag check, cycle 2 write data RAM with byte
  enables + set dirty, then ack). Keep it simple; optimise in T10.
- Miss: if dirty, read the 8 old words into the line buffer and write the line
  back; then refill; then replay the access.
- Reset invalidate like the I-cache.

**T6.3 `mem_arb`**: two line clients (D-cache priority, I-cache second) →
one `line_master`. Fixed priority, never interrupts a burst.

**T6.4 `bus_decode`** (core D-port → D-cache / MMIO / boot ROM) and
`mmio_mux` (register blocks by `addr[11:8]`, framebuffer by `addr[24]`).
MMIO slave interface used by every register block:
`m_req`, `m_we`, `m_be`, `m_addr[11:0]`, `m_wdata` → `m_ack`, `m_rdata`
(ack 1 cycle after req for all our blocks).

**T6.5 Tests**
- `tb_icache`, `tb_dcache` with a scripted sequence (hits, misses, conflict
  evictions, dirty writebacks, byte stores) checked against a flat reference
  memory array inside the testbench.
- Random stress test: 50 000 random loads/stores of all sizes over a small
  address range (forces evictions), checked against the reference.
- Re-run all ISA tests and T5.15 with code placed in the DDR model at
  `0x4000_0000` behind the caches (boot ROM just jumps there).

### Phase 7 — SoC integration

**T7.1 `boot_rom`** (`sw/boot/start.S` → `boot_rom.hex`, ≤ 4 KB)
- Read the boot-info block at `0x4FFF_F000`. If magic matches: set `sp` to
  `0x4800_0000`, jump to the entry point.
- Otherwise: blink `SYS_LED` with a recognisable pattern forever.

**T7.2 IO blocks** (each with a testbench): `sys_regs`, `timer`
(param `CLK_HZ`, 1 µs tick), `console` (256-byte `fifo_sync`), `kbd_fifo`
(16 deep), `ctrl_regs` (full section 4.3), `audio_regs` stub (for now: accept
writes, report level 0).

**T7.3 `soc_top`**: core + caches + arbiter + line_master + bus decode +
boot ROM + all MMIO blocks + video (`fb_ram`, `palette_ram`, `video_regs`,
`video_out`, `video_timing`). Ports: clocks/resets, `ddr_*`, `lw_*`, video
pins, LEDs/keys/switches. No HPS inside (the HPS lives in `de10_top`).

**T7.4 SoC simulation (L3)**
- `tb_soc` with `avalon_ddr_model` preloaded from hex files (firmware at
  `0x2000_0000`, boot-info block written by the testbench), and a model of
  the LW bridge master to read the console.
- Programs: `hello` (prints via console; tb checks text), `memtest`
  (C, 256 KB, checks), `fbtest` (writes palette + a pattern to framebuffer 0,
  tb checks a few framebuffer words), `timer` (reads timer twice, checks
  increase).

**T7.5 Board bring-up [HW]**
- `doomctl` v1: `doomctl run <firmware.bin> [<wad>]` loads files into DDR,
  writes the boot-info block, releases reset, then loops: prints console
  bytes, forwards keyboard events (T9), on `halted` prints `DBG_*` registers
  and exits.
- Human runs `hello`, `memtest` (64 MB), `fbtest` (pattern on TV),
  and reports Fmax for `clk_sys`.

### Phase 8 — Software platform (`sw/common/`)

**T8.1 `link.ld` + `crt0.S`**
- Memory: one region at `0x4000_0000`, 8 MB for code+data+bss.
- `crt0`: set `sp` = `0x4800_0000`, `gp` (`__global_pointer$`), zero `.bss`,
  call `main`, write its return value to `SYS_EXIT`.
- Symbols `_heap_start` (= `0x4080_0000`) and `_heap_end` (= `0x47F0_0000`).

**T8.2 `mmio.h`**: register addresses from section 4.2 and inline
read/write helpers (`volatile uint32_t *`).

**T8.3 `syscalls.c`** (newlib/picolibc stubs)
- `_sbrk` within `_heap_start`..`_heap_end` (return `-1` + `ENOMEM` when full).
- `_write` for fd 1/2 → console (convert `\n` to `\r\n` optional).
- **Memory file system** for the WAD:
  - `_open(name)`: if the base name equals the boot-info WAD name → return
    fd 3 (read-only). Anything opened for writing (config, savegames):
    return a fd backed by a small RAM file table (4 files × 64 KB) so the
    game does not crash; contents are lost on reset (that is fine).
    Any other read of an unknown file → `-1`, `ENOENT`.
  - `_read`, `_lseek`, `_close`, `_fstat` (report size), `_isatty`.
- `_exit` → `SYS_EXIT`. `_gettimeofday` from the µs timer.
- Unused stubs (`_kill`, `_getpid`, `_link`, `_unlink`) return errors.

**T8.4 Host test (L4)**
- Build `syscalls.c` on the PC with `-DHOST_TEST` where MMIO and the boot-info
  block are plain arrays; load a real `freedoom1.wad` into the fake WAD
  region; check `fopen/fread/fseek` give the same bytes as reading the file
  normally. Run with AddressSanitizer.

### Phase 9 — Doom bring-up

**T9.1 Add doomgeneric**
- `git submodule add https://github.com/ozkl/doomgeneric sw/doom/doomgeneric`.
- `sw/doom/Makefile`: compile all engine `.c` files except other platform
  backends (`doomgeneric_sdl.c`, `doomgeneric_xlib.c`, `doomgeneric_win.c`,
  etc.) and SDL sound/music files. Inspect the source tree to get the exact
  list.
- Flags: `-march=rv32im -mabi=ilp32 -O2 -DDOOMGENERIC_RESX=320
  -DDOOMGENERIC_RESY=200 -DCMAP256 -DNORMALUNIX` (verify which defines
  doomgeneric actually uses).
- Any engine change goes into `sw/doom/patches/NNNN-*.patch`, applied by the
  Makefile. Keep patches minimal and explain each one in its header.

**T9.2 `dg_de10.c`** — implements the doomgeneric platform functions:
- `DG_Init`: init console, video (both buffers black), audio off.
- `DG_DrawFrame`: copy `DG_ScreenBuffer` (320×200 bytes) to the back
  framebuffer with 32-bit stores, write `VID_CTRL` to swap, wait while
  `swap_pending` (bounded wait). If the palette changed since the last frame,
  write all 256 entries to `VID_PAL`.
- Palette: in `CMAP256` mode the engine must expose the current palette
  (with gamma applied). If doomgeneric has no hook for this, add a small
  patch in `I_SetPalette` that stores it into a global array + dirty flag.
- `DG_SleepMs`: busy-wait on the timer. `DG_GetTicksMs`: timer / 1000.
- `DG_GetKey`: pop `KBD_DATA`, translate Linux key codes to Doom keys with a
  table (arrows, Ctrl=fire, Space=use, Shift=run, Alt=strafe, Esc, Enter,
  Y/N, Tab=map, digits 1–7=weapons, F1–F12, `-`/`=`, letters).
- `DG_SetWindowTitle`: no-op.
- `main()`: build `argv` = `{"doom", "-iwad", <name from boot-info>}` and call
  `doomgeneric_Create` then loop `doomgeneric_Tick()`.
- Print an FPS line to the console every 5 seconds (frames / µs).

**T9.3 `doomctl` keyboard forwarding**
- Find the first `/dev/input/event*` that reports `EV_KEY` with letter keys;
  `EVIOCGRAB` it; for each `EV_KEY` event with value 0 or 1 (ignore repeats,
  value 2) write `{pressed, code}` to `KBD_PUSH`.
- `Ctrl+Alt+Backspace` (or a command-line option) exits `doomctl` and puts
  the RISC-V back into reset.

**T9.4 First boot [HW]**
- Expected issues to watch for and how to diagnose:
  - Halt with misaligned load/store → print `DBG_PC`/`DBG_ADDR`, find the
    function with `riscv-none-elf-addr2line -e doom.elf <pc>`; fix with a
    patch or add misaligned-access support to the LSU (split into two
    accesses) if it happens in many places.
  - Hang → `DBG_PC` and `PERF_INSTR` show where it loops.
  - Out of memory → raise the zone size or heap.
- Done when: the title screen appears, menus work with the keyboard, E1M1 can
  be played (silent), and the FPS value is recorded.

### Phase 10 — Performance

Goal: ≥ 20 FPS average in the first level at 100 MHz. Measure after every
step and log the numbers in `docs/PROGRESS.md` (FPS, Fmax, ALMs, M10Ks).

Do the steps in order; stop when the goal is met (but always do T10.1):

| Task | Change | Notes |
|---|---|---|
| T10.1 | Raise `clk_sys` toward 100 MHz | Fix critical paths found by the Timing Analyzer. Typical hot spots: cache tag compare → stall → next-PC mux → RAM address; forwarding muxes; multiplier (register its inputs). Add pipeline registers rather than lowering the clock. |
| T10.2 | Profile | Software sampling: every N frames `doomctl` reads `DBG_PC` many times per second and builds a histogram by function (`nm` + `addr2line`). Find the top functions. |
| T10.3 | 1-cycle store hits in the D-cache | write in the MEM cycle after tag check with a 1-entry store bypass for an immediately following load to the same word |
| T10.4 | Branch prediction | 64-entry BTB + 2-bit counters, looked up in IF; misprediction recovery in EX |
| T10.5 | Bigger caches | I$ 16 KB, D$ 32 KB (check M10K budget) |
| T10.6 | Freeze only what must freeze | an I-cache miss should not stop a load/store already in MEM, etc. Only if profiling shows memory stalls dominate. |
| T10.7 | Faster `FixedDiv` | software: a patch using a 32-bit reciprocal path, or a radix-4 divider in hardware |
| T10.8 | Render straight into the framebuffer | only if the frame copy shows up in the profile |

Every change must keep all L1–L3 tests passing.

### Phase 11 — Sound effects

**T11.1 `i2s_tx`** (clk_aud): `MCLK = clk_aud` (12.288 MHz),
`SCLK = MCLK/4` (3.072 MHz = 64×48 kHz), `LRCLK = MCLK/256` (48 kHz), left
channel when LRCLK low, 16-bit samples MSB first, 1 SCLK delay after LRCLK
change (standard I2S), padded to 32-bit slots. Input: `sample_l`,
`sample_r`, `sample_req` pulse at each frame start.
Test: decode the serial stream in the testbench and compare.

**T11.2 `aud_rate`** (clk_aud): reads the async FIFO at 11025 Hz average using
a phase accumulator (`acc += 11025` per 48 kHz tick; when `acc ≥ 48000`,
subtract 48000 and pop a new sample). Holds the last sample between pops
(sample-and-hold). On underrun: output 0 and set the underrun flag. Applies
master volume (signed × unsigned 8-bit, `>>8`).

**T11.3 `audio_regs` (real)**: `AUD_DATA` writes into `fifo_async`
(2048 deep), `AUD_STAT` level from the write side, `AUD_CTRL`.

**T11.4 PLL1 + pins [HW]**: fractional PLL for 12.288 MHz; connect
`HDMI_MCLK`, `HDMI_SCLK`, `HDMI_LRCLK`, `HDMI_I2S`. Test firmware
`audiotest` plays a 440 Hz sine (left) and 880 Hz (right). Human confirms
sound on the TV. If silent: check ADV7513 audio registers (T2.3 table,
`0x0A`, `0x0C`, `0x15`, N value) against the programming guide.

**T11.5 `i_de10sound.c`** — Doom sound module (look at `i_sound.c` in
doomgeneric to see the `sound_module_t` interface and how modules are
registered; patch the registration if needed):
- 8 channels. `StartSound` looks up the lump `DS<name>`, parses the header
  (format, sample rate, length; skip the padding bytes), stores pointer,
  length, step (rate/11025 in 16.16 fixed point), left/right volume from
  `vol` and `sep`.
- `UpdateSound` (called once per game tic): compute how many samples the FIFO
  needs to reach a target fill of ~1500 samples (read `AUD_STAT`), mix that
  many samples from all channels (8-bit unsigned → signed, × volume, sum,
  clamp to 16-bit), write them to `AUD_DATA`.
- `SoundIsPlaying`, `StopSound`, `UpdateSoundParams` as the interface needs.
- Done when [HW]: weapon, door and monster sounds play with correct stereo
  panning, no crackling during normal play (no underruns reported).

### Phase 12 — Music (OPL2-compatible FM synth in Verilog)

Doom music is stored in MUS format and was played on an OPL2 FM chip using
the `GENMIDI` instrument lump (Freedoom includes one). We implement a
register-compatible subset of the Yamaha YM3812 in Verilog and drive it with
a port of Chocolate Doom's OPL music player (GPL-2.0).

Spec sources: the Yamaha YM3812 application manual and public OPL2
programming guides. Implement from the documented behaviour. Do not copy
code from software emulators.

Hardware (`rtl/audio/opl/`, clk_aud domain, one operator slot processed per
clock in a time-multiplexed pipeline; 18 slots per output sample):

| Task | Module | Content |
|---|---|---|
| T12.1 | `opl_regs.v` | register file for 0x01, 0x08, 0x20–0x35, 0x40–0x55, 0x60–0x75, 0x80–0x95, 0xA0–0xA8, 0xB0–0xB8, 0xC0–0xC8, 0xE0–0xF5 (rhythm mode 0xBD not needed). Written from the OPL write FIFO (sys → aud, `fifo_async`). Slot-to-register mapping table. |
| T12.2 | `opl_phase.v` | per-slot phase accumulator. Increment from F-number, block and MULT. Scale by 49716/48000 (Q1.15 constant) because we run at 48 kHz instead of the chip's native rate, so pitch stays correct. |
| T12.3 | `opl_env.v` | per-slot envelope state (attack, decay, sustain, release), rates with key scaling, total level, KSL. Output attenuation in the log domain. |
| T12.4 | `opl_tables.v` + `scripts/gen_opl_tables.py` | quarter-wave log-sine table and exponent table, **generated mathematically** by the script into hex files. |
| T12.5 | `opl_op.v` | operator: phase + modulation → waveform select (4 waveforms) → log-sin lookup + attenuation → exp lookup → signed output |
| T12.6 | `opl_chan.v` | per channel: feedback for operator 1, connection (FM or additive), accumulate 9 channels into one sample |
| T12.7 | `opl_top.v` | slot sequencer, ties everything together, outputs one signed 16-bit sample per 48 kHz tick |
| T12.8 | `aud_mix.v` | `sfx × sfx_vol + music × music_vol`, saturate to 16-bit, feed `i2s_tx` |

Tests: unit tests per module; `tb_opl_top` plays a single sine note
(connection = additive, operator 2 silent) and checks frequency by counting
zero crossings (±1 %), and checks that key-off decays to silence.

Software:
- **T12.9** `i_de10music.c`: port the OPL music player from Chocolate Doom
  (`i_oplmusic.c`, plus the MUS reader `mus2mid.c`/`midifile.c` if needed).
  Replace its OPL backend with direct writes to `OPL_ADDR`/`OPL_DATA`.
  Replace its timer callbacks with a function `music_poll(now_us)` that runs
  all due callbacks; call it from the main loop and from `UpdateSound`.
  Keep GPL headers; list the origin of every ported file in
  `sw/doom/NOTICE.md`.
- **T12.10 [HW]** Human confirms title-screen and level music plays at the
  right tempo and pitch, together with sound effects.

Fallback if the custom synth takes too long: use an existing open-source
Verilog OPL core with a compatible licence as a drop-in behind the same
`OPL_ADDR/OPL_DATA` interface. Ask the human before doing this.

### Phase 13 — Finish

- **T13.1** Auto-start: a systemd service (or `/etc/rc.local` line) on the SD
  card that runs `doomctl run /root/doom.bin /root/freedoom1.wad` at boot.
- **T13.2** `KEY[1]` restarts the game (pulses `cpu_reset` through
  `ctrl_regs`; `doomctl` notices and reloads).
- **T13.3** README in English and Hebrew: what it is, how to build
  (RTL, firmware, ARM tool), how to prepare the SD card, controls, licences.
- **T13.4** Final resource/timing report in `docs/PROGRESS.md`.

---

## 10. Risks and fallbacks

| Risk | Sign | Fallback |
|---|---|---|
| F2SDRAM port not usable with the stock preloader | memtest fails or hangs at T4.4 | regenerate preloader from our handoff (SoC EDS), else route B (F2H AXI bridge) |
| Timing closure at 100 MHz | Fmax < 100 MHz | pipeline the hot path (see T10.1); accept 75 MHz if FPS goal is still met |
| Doom too slow | < 20 FPS after T10.5 | do T10.6–T10.8; lower detail (`detailLevel` low = half-width columns) |
| Misaligned accesses in Doom code | halt cause 5/6 | patch the code, or implement split misaligned accesses in the LSU |
| HDMI audio silent | T11.4 | re-check ADV7513 audio registers, MCLK ratio, N value; test with a known I2S pattern |
| M10K budget | fitter error | shrink caches first (keep framebuffers), check RAMs inferred correctly (T1.9) |
| OPL synth effort | Phase 12 slips | play SFX only; music as optional, or licensed core (ask human) |

---

## 11. Reference

### 11.1 Resource budget (5CSEBA6: ~41 900 ALMs, 553 M10K blocks, 112 DSP blocks — verify)

| Block | M10K estimate |
|---|---|
| Framebuffers 2 × 64000 B | ~104 |
| I$ 8 KB + tags | ~9 |
| D$ 16 KB + tags | ~17 |
| Boot ROM, palette, FIFOs, console | ~10 |
| OPL tables | ~4 |
| **Total** | **~145 (≈ 26 %)** |

### 11.2 Doom key codes

Use `doomkeys.h` from doomgeneric for the Doom side. The Linux side codes come
from `linux/input-event-codes.h` (e.g. `KEY_UP`=103, `KEY_DOWN`=108,
`KEY_LEFT`=105, `KEY_RIGHT`=106, `KEY_LEFTCTRL`=29, `KEY_SPACE`=57,
`KEY_ESC`=1, `KEY_ENTER`=28, `KEY_LEFTSHIFT`=42, `KEY_LEFTALT`=56,
`KEY_TAB`=15). Put the table in `dg_de10.c` only.

### 11.3 Licences

- doomgeneric and Chocolate Doom code: GPL-2.0. The firmware binary is
  therefore GPL; the repository must keep the source available.
- Freedoom data: BSD-style licence; still not committed (size), fetched by script.
- `riscv-tests`: BSD.
- Our own RTL and tools: licence chosen by the human (ask at T0.1; suggest
  GPL-2.0-or-later for simplicity).
