# Agent instructions

This repo builds DOOM (open-source engine + Freedoom data) on a DE10-Nano.
The game runs on our own RV32IM CPU written in Verilog inside the FPGA.

The full plan, memory maps, coding rules and task list are in
[`docs/PLAN.md`](docs/PLAN.md). Read sections 0-8 before doing anything.

Short version of the rules:
- One task at a time, in plan order. Log it in `docs/PROGRESS.md`. One commit per task: `T<id>: <summary>`.
- Verilog-2001 only. One module per file, <= 200 lines (aim for 120). `default_nettype none`.
- Every RTL module has a self-checking Icarus testbench printing `PASS tb_<name>` / `FAIL tb_<name>`.
- `make -C sim test` must pass before every commit. Never weaken a test.
- [HW] tasks: write instructions in `docs/hw_checkpoints/`, then stop and ask the human.
- Never commit `*.wad`, Quartus build folders, or generated binaries.
