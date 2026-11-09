# Tools

Everything needed to build and test this project, with the commands that were
actually verified. `scripts/check_tools.sh` prints the version of each tool and
exits non-zero if one is missing.

| Tool | Used for | Verified version |
|---|---|---|
| `iverilog`, `vvp` | every simulation, `make -C sim test` | 13.0 (stable), Ubuntu 24.04 |
| `riscv-none-elf-gcc` | RISC-V firmware (`sw/`) | xPack 15.2.0-1 |
| `arm-linux-gnueabihf-gcc` | the ARM helper `doomctl` (T4.4) | not yet exercised |
| `python3` | hex/bin conversion scripts | 3.12.3 |
| Quartus Prime Lite | synthesis and programming, human only | 17.1 with Cyclone V support |

Run the check with:

```sh
./scripts/check_tools.sh
```

## Icarus Verilog

On a normal Debian/Ubuntu machine with root:

```sh
sudo apt-get update
sudo apt-get install -y iverilog
iverilog -V | head -1     # Icarus Verilog version 13.0 (stable) (v13_0)
```

Ubuntu 24.04 itself ships 12.0; 13.0 is what the `-g2005` testbenches were run
with. `sim/Makefile` only needs `iverilog` and `vvp` on `PATH`, and honours
`IVERILOG=`/`VVP=` overrides, so any recent package works.

Without root (the agent sandbox has no `sudo`, for example), unpack the Ubuntu
package and wrap the binaries. These exact commands worked on Ubuntu 24.04
x86-64:

```sh
mkdir -p /tmp/ivl && cd /tmp/ivl
curl -sSLO http://archive.ubuntu.com/ubuntu/pool/universe/i/iverilog/iverilog_13.0-2_amd64.deb
dpkg-deb -x iverilog_13.0-2_amd64.deb root
mkdir -p bin
L=/tmp/ivl/root/usr/lib/x86_64-linux-gnu/ivl
printf '#!/bin/sh\nexec /tmp/ivl/root/usr/bin/iverilog -B%s "$@"\n' "$L" > bin/iverilog
printf '#!/bin/sh\nexec /tmp/ivl/root/usr/bin/vvp -M%s "$@"\n'          "$L" > bin/vvp
chmod +x bin/iverilog bin/vvp
export PATH=/tmp/ivl/bin:$PATH
iverilog -V | head -1
```

Notes:

- Pick the current package from
  <http://archive.ubuntu.com/ubuntu/pool/universe/i/iverilog/> (the directory
  listing shows the version and the `amd64`/`arm64`/`amd64v3` builds).
- `-B` must point at the directory holding `ivlpp` and `ivl`, and `vvp -M` at
  the directory holding the `.vpi` modules — both are
  `<unpacked root>/usr/lib/<triplet>/ivl/`.
- `/tmp` does not survive a sandbox restart or archive, so re-run the block
  when a new session starts. Nothing in the repository depends on this setup.

## RISC-V GCC (firmware)

The xPack build is a single tarball, no installer, no root, and it carries the
`rv32im/ilp32` newlib multilib we need:

```sh
mkdir -p "$HOME/xpack" && cd "$HOME/xpack"
curl -LO https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz
tar xzf xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz
export PATH="$HOME/xpack/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH"
riscv-none-elf-gcc --version
```

The download is about 430 MB. On an ARM host use the `-linux-arm64` asset, and
for a newer toolchain take the version from
<https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases> and use
it in both the file name and the unpacked directory name.

Alternative: `sudo apt-get install gcc-riscv64-unknown-elf` (untested here —
`scripts/check_tools.sh` will tell you whether it carries an `rv32im/ilp32`
multilib).

## ARM GCC (the HPS-side helper)

```sh
sudo apt-get install -y gcc-arm-linux-gnueabihf
```

`doomctl` runs under the board's Linux, which is armhf (`docs/PLAN.md` T4.4).
Not exercised yet — the first real build happens at T4.4, and the exact
`arm-linux-gnueabihf-gcc` version goes into `docs/PROGRESS.md` then. Point
`ARM_GCC=` at a different compiler if the board image turns out to be
gnueabi/armel.

## Python 3

Comes with Ubuntu; `sudo apt-get install -y python3` if missing. Used by the
hex/`bin` conversion scripts and the simulation helpers.

## Verified firmware flags (2026-11-09)

Confirmed with xPack `riscv-none-elf-gcc` 15.2.0 and a hand-written linker
script placing `.text` at the firmware base `0x4000_0000` (PLAN section 4.1).

The multilib exists:

```sh
$ riscv-none-elf-gcc -print-multi-lib | grep 'rv32im/ilp32'
rv32im/ilp32;@march=rv32im@mabi=ilp32
```

Bare program, no libc at all:

```sh
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding -nostdlib \
    -nostartfiles -T link.ld -Wl,--gc-sections -o bare.elf crt0.S bare.c
```

Result: `Entry point address: 0x40000000`, 40 bytes of `.text`, and
`Tag_RISCV_arch: "rv32i2p1_m2p0_zmmul1p0"` — M instructions are generated and
no compressed (`C`) instructions, which matches the RV32IM core.

Same source with newlib (`memcpy` + `printf`):

```sh
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding -nostartfiles \
    -T link.ld -Wl,--gc-sections --specs=nosys.specs -o hello.elf crt0.S main.c
```

Result: links, entry `0x40000000`, `.text` 59,296 B, `.data` 1,740 B, `.bss`
442 B. `--specs=nosys.specs` prints one warning per unimplemented syscall
(`_close`, `_write`, `_sbrk`, …) and `warning: hello.elf has a LOAD segment
with RWX permissions`; both are expected with this throwaway script — T8.3
supplies the real syscall stubs and the real script.

Things the linker script must provide, learned the hard way:

- `PROVIDE(end = .);` (and `_end`) after `.bss`, otherwise newlib's `_sbrk` in
  `libnosys.a` fails to link with `undefined reference to 'end'`.
- `-nostartfiles` skips newlib's `crt0`, so our own `crt0.S` must set `sp` from
  the linker symbol for the top of the stack (PLAN section 4.1:
  `0x4800_0000`) and `call main`.
- `0x4000_0000` and the stack at `0x4800_0000` are inside the low 2 GiB, so the
  default `-mcmodel=medlow` is fine; no extra code-model flag is needed.
