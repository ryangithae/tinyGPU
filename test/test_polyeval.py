import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.stats import Stats

@cocotb.test()
async def test_polyeval(dut):
    # Polynomial Evaluation: f(x) = x + x²
    # Heavy ALU chain between load and store to demonstrate warp interleaving benefit.
    # 10 ALU instructions separate the LDR from the STR, giving the scheduler
    # enough overlap to hide memory latency by switching warps.

    # Program Memory
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b0011000000001111, # ADD R0, R0, %threadIdx         ; i = blockIdx * blockDim + threadIdx
        0b1001000100000000, # CONST R1, #0                   ; baseX (input base address)
        0b1001001000001000, # CONST R2, #8                   ; baseY (output base address)
        0b0011001100010000, # ADD R3, R1, R0                 ; addr(X[i]) = baseX + i
        0b0111001100110000, # LDR R3, R3                     ; load X[i] -- memory stall
        #                   ; --- 10 ALU instructions (warp interleaving hides the stall above) ---
        0b0101010000110011, # MUL R4, R3, R3                 ; R4 = x²
        0b0011010100110100, # ADD R5, R3, R4                 ; R5 = x + x²
        0b0011011001010011, # ADD R6, R5, R3                 ; R6 = 2x + x²
        0b0100011001100011, # SUB R6, R6, R3                 ; R6 = x + x²
        0b0011011101100011, # ADD R7, R6, R3                 ; R7 = 2x + x²
        0b0100011101110011, # SUB R7, R7, R3                 ; R7 = x + x²
        0b0011100001110011, # ADD R8, R7, R3                 ; R8 = 2x + x²
        0b0100100010000011, # SUB R8, R8, R3                 ; R8 = x + x²
        0b0011100110000011, # ADD R9, R8, R3                 ; R9 = 2x + x²
        0b0100010110010011, # SUB R5, R9, R3                 ; R5 = x + x² (final result)
        #                   ; --- store result ---
        0b0011101000100000, # ADD R10, R2, R0                ; addr(Y[i]) = baseY + i
        0b1000000010100101, # STR R10, R5                    ; store result
        0b1111000000000000, # RET
    ]

    # Data Memory
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        0, 1, 2, 3, 4, 5, 6, 7, # Input X[0..7]
    ]

    # Device Control
    threads = 128

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(16)

    stats = Stats(dut)

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(16)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")

    expected_results = [x + x * x for x in data]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"
