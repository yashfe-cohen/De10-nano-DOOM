# SPDX-License-Identifier: GPL-2.0-or-later
#
# sim/Makefile -- build and run the Icarus Verilog testbenches.
#
#   make -C sim test             run every sim/tb_*.v (exits non-zero on any
#                                failure; zero testbenches is legal)
#   make -C sim T=<name>         run one testbench (tb_<name> or bare <name>)
#   make -C sim VCD=1 T=<name>   also dump waves (testbenches honour +vcd)
#   make -C sim clean            remove sim/build/
#
# Rules (docs/PLAN.md section 6): every testbench is self-checking and prints
# exactly one final line "PASS tb_<name>" or "FAIL tb_<name> (<n> errors)".
# A testbench only counts as passed when vvp exits 0 *and* that exact PASS
# line is present, so a crash or a missing PASS line is always a failure.
# Logs land in sim/build/.

IVERILOG ?= iverilog
VVP      ?= vvp

IVFLAGS  ?= -g2005 -Wall -I../rtl -I../rtl/cpu -I../rtl/common
BUILD    := build

# rtl/board is deliberately absent: it instantiates Quartus IP (PLLs, HPS)
# which has no behavioural model in Icarus. Every other RTL file is compiled
# into every testbench, and "-s $(tb)" makes that testbench the only root, so
# modules the testbench does not use are never elaborated.
RTL_DIRS := common cpu mem video hdmi audio audio/opl io soc
RTL      := $(foreach d,$(RTL_DIRS),$(wildcard ../rtl/$(d)/*.v))
MODELS   := $(wildcard models/*.v)

TESTS := $(sort $(basename $(notdir $(wildcard tb_*.v))))
ifdef T
TESTS := $(if $(filter tb_%,$(T)),$(T),tb_$(T))
endif

VCDARG :=
ifeq ($(VCD),1)
VCDARG := +vcd
endif

.PHONY: all test clean

all: test

test:
	@mkdir -p $(BUILD)
	@set -e; \
	total=0; bad=""; \
	if [ -n "$(strip $(TESTS))" ] && ! command -v $(IVERILOG) >/dev/null; then \
	  echo "sim: '$(IVERILOG)' not found in PATH -- see docs/tools.md"; exit 1; \
	fi; \
	for tb in $(TESTS); do \
	  total=$$((total + 1)); \
	  if ! $(IVERILOG) $(IVFLAGS) -s $$tb -o $(BUILD)/$$tb \
	       $(RTL) $(MODELS) $$tb.v > $(BUILD)/$$tb.build.log 2>&1; then \
	    echo "FAIL $$tb (compile error, see $(BUILD)/$$tb.build.log)"; \
	    bad="$$bad $$tb"; \
	    continue; \
	  fi; \
	  if $(VVP) $(BUILD)/$$tb $(VCDARG) > $(BUILD)/$$tb.log 2>&1 \
	     && grep -qx "PASS $$tb" $(BUILD)/$$tb.log; then \
	    echo "PASS $$tb"; \
	  else \
	    echo "FAIL $$tb (no 'PASS $$tb' line, see $(BUILD)/$$tb.log)"; \
	    bad="$$bad $$tb"; \
	  fi; \
	done; \
	if [ $$total -eq 0 ]; then echo "sim: no testbenches yet (0 run)"; fi; \
	if [ -n "$$bad" ]; then \
	  echo "sim: FAILED:$$bad"; exit 1; \
	fi; \
	echo "sim: $$total/$$total passed"

clean:
	rm -rf $(BUILD)
