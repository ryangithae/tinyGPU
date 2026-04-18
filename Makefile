.PHONY: test compile clean

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)
TOPLEVEL=gpu

clean:
	rm -rf build/*

test_%:
	make compile
	make build/iverilog_dump_$*.sv
	iverilog -o build/sim.vvp -s $(TOPLEVEL) -s iverilog_dump_$* -g2012 build/$(TOPLEVEL).v build/iverilog_dump_$*.sv
	COCOTB_TEST_MODULES=test.test_$* vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp

compile:
	make compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	sv2v -w build/$*.v src/$*.sv

build/iverilog_dump_%.sv:
	echo 'module iverilog_dump_$*();'        > $@
	echo 'initial begin'                    >> $@
	echo '    $$dumpfile("build/$*.vcd");'  >> $@
	echo '    $$dumpvars(0, $(TOPLEVEL));'  >> $@
	echo 'end'                             >> $@
	echo 'endmodule'                       >> $@

show_%: build/%.vcd
	gtkwave $