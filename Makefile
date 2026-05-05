# =============================================================================
# tinyGPU Simulation Makefile
# =============================================================================
#
# RUNNING TESTS
#   make check-base               run all tests against tinyGPU_base
#   make check-warpinterleaving   run all tests against tinyGPU_warpinterleaving
#   make check-memcoalesce        run all tests against tinyGPU_memcoalesce
#   make check-combined           run all tests against tinyGPU_combined
#
# ADDING TESTS
#   add the test filename to the TESTS variable below e.g.
#   TESTS = test_matadd test_matmul
#   the test file must exist at test/test_<name>.py
#
# VIEWING WAVEFORMS
#   make show_gpu_base_test_matadd
#   vcd files are generated per impl+test in build/
#   e.g. build/gpu_base_test_matadd.vcd
#
# LOGS
#   written to test/logs/log_<impl>_<test>_<timestamp>.txt
#   make clear_logs       delete all logs
#   make clear_logs_base  delete logs for one impl
#
# COMPILATION
#   each impl compiles once into build/gpu_<impl>.v
#   make clean to force recompilation
#
# DIRECTORY STRUCTURE
#   tinyGPU_base/             original implementation
#   tinyGPU_warpinterleaving/ warp interleaving branch
#   tinyGPU_memcoalesce/      memory coalescing branch
#   tinyGPU_combined/         both optimizations merged
#   test/                     python testbenches and helpers
#   build/                    compiled outputs (gitignored)
# =============================================================================
.PHONY: clean clear_logs

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)

TESTS = test_matadd test_matmul test_broadcast test_scalarmatvec test_polyeval

build/gpu_base.v:
	sv2v -I tinyGPU_base/* -w build/gpu_base.v
	sv2v -w build/alu_base.v tinyGPU_base/alu.sv
	echo "" >> build/gpu_base.v
	cat build/alu_base.v >> build/gpu_base.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu_base.v >> build/temp.v
	mv build/temp.v build/gpu_base.v

build/gpu_warpinterleaving.v:
	sv2v -I tinyGPU_warpinterleaving/* -w build/gpu_warpinterleaving.v
	sv2v -w build/alu_warpinterleaving.v tinyGPU_warpinterleaving/alu.sv
	echo "" >> build/gpu_warpinterleaving.v
	cat build/alu_warpinterleaving.v >> build/gpu_warpinterleaving.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu_warpinterleaving.v >> build/temp.v
	mv build/temp.v build/gpu_warpinterleaving.v

build/gpu_memcoalesce.v:
	sv2v -I tinyGPU_memcoalesce/* -w build/gpu_memcoalesce.v
	sv2v -w build/alu_memcoalesce.v tinyGPU_memcoalesce/alu.sv
	echo "" >> build/gpu_memcoalesce.v
	cat build/alu_memcoalesce.v >> build/gpu_memcoalesce.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu_memcoalesce.v >> build/temp.v
	mv build/temp.v build/gpu_memcoalesce.v

build/gpu_combined.v:
	sv2v -I tinyGPU_combined/* -w build/gpu_combined.v
	sv2v -w build/alu_combined.v tinyGPU_combined/alu.sv
	echo "" >> build/gpu_combined.v
	cat build/alu_combined.v >> build/gpu_combined.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu_combined.v >> build/temp.v
	mv build/temp.v build/gpu_combined.v

check-%: build/gpu_%.v
	@for test in $(TESTS); do \
		echo "=== $$test on $* ==="; \
		echo 'module iverilog_dump();'                         > build/iverilog_dump_$*_$$test.sv; \
		echo 'initial begin'                                  >> build/iverilog_dump_$*_$$test.sv; \
		echo '    $$dumpfile("build/gpu_$*_'$$test'.vcd");'  >> build/iverilog_dump_$*_$$test.sv; \
		echo '    $$dumpvars(0, gpu);'                        >> build/iverilog_dump_$*_$$test.sv; \
		echo 'end'                                           >> build/iverilog_dump_$*_$$test.sv; \
		echo 'endmodule'                                     >> build/iverilog_dump_$*_$$test.sv; \
		iverilog -o build/gpu_$*_$$test.vvp -s gpu -s iverilog_dump \
			-g2012 build/gpu_$*.v build/iverilog_dump_$*_$$test.sv; \
		TINYGPU_IMPL=$* TINYGPU_TEST=$$test COCOTB_TEST_MODULES=test.$$test \
			vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/gpu_$*_$$test.vvp; \
	done

show_%:
	gtkwave build/$*.vcd

clean:
	rm -rf build/*

clear_logs:
	rm -rf test/logs/log_*

clear_logs_%:
	rm -rf test/logs/log_$**