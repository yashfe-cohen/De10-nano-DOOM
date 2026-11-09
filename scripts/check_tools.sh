#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# check_tools.sh -- print the version of every tool this project needs and
# fail clearly when one is missing.
#
#   scripts/check_tools.sh
#   RISCV_GCC=$HOME/xpack/bin/riscv-none-elf-gcc scripts/check_tools.sh
#   ARM_GCC=arm-none-linux-gnueabihf-gcc scripts/check_tools.sh
#
# Exits 0 when everything is present, 1 otherwise. Install commands and the
# exact compile flags we verified live in docs/tools.md.

set -u

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
RISCV_GCC=${RISCV_GCC:-riscv-none-elf-gcc}
ARM_GCC=${ARM_GCC:-arm-linux-gnueabihf-gcc}
PYTHON=${PYTHON:-python3}

missing=0

# report <label> <command> <hint> [version arguments...]
report() {
	label=$1
	cmd=$2
	hint=$3
	shift 3
	if command -v "$cmd" >/dev/null 2>&1; then
		path=$(command -v "$cmd")
		version=$("$cmd" "$@" 2>&1 | head -n 1 | sed 's/[[:space:]]*$//')
		[ -n "$version" ] || version="(no version output)"
		printf 'ok       %-24s %s\n' "$label" "$path"
		printf '         %-24s %s\n' "" "$version"
	else
		printf 'MISSING  %-24s %s\n' "$label" "not found in PATH"
		printf '         %-24s %s\n' "" "$hint"
		missing=$((missing + 1))
	fi
}

printf 'toolchain check (install commands: docs/tools.md)\n\n'
report iverilog "$IVERILOG"   "apt-get install iverilog (docs/tools.md)"    -V
report vvp      "$VVP"        "apt-get install iverilog (docs/tools.md)"    -V
report python3  "$PYTHON"     "apt-get install python3 (docs/tools.md)"     --version
report "$(basename "$RISCV_GCC")" "$RISCV_GCC" \
	"xPack tarball or gcc-riscv64-unknown-elf (docs/tools.md)" --version
report "$(basename "$ARM_GCC")" "$ARM_GCC" \
	"apt-get install gcc-arm-linux-gnueabihf (docs/tools.md)" --version

# The CPU is RV32IM, so a toolchain without that multilib cannot build us.
if command -v "$RISCV_GCC" >/dev/null 2>&1; then
	if "$RISCV_GCC" -print-multi-lib 2>/dev/null | grep -q 'rv32im/ilp32;'; then
		printf 'ok       %-24s %s\n' "RV32IM multilib" "rv32im/ilp32 present"
	else
		printf 'MISSING  %-24s %s\n' "RV32IM multilib" \
			"$RISCV_GCC has no rv32im/ilp32 multilib"
		missing=$((missing + 1))
	fi
fi

if [ "$missing" -ne 0 ]; then
	printf '\ntoolcheck: %d missing -- install commands are in docs/tools.md\n' "$missing"
	exit 1
fi
printf '\ntoolcheck: all tools present\n'
