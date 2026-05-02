import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.stats import Stats

@cocotb.test()
async def test_scalarmatvec(dut):
    """Scalar-matrix-vector multiply: y[i] = scalar * dot(row_i, x)

    Memory layout:
        addr 0       : scalar (shared by ALL threads)
        addr 1-4     : vector x[0..3] (shared by ALL threads)
        addr 8-11    : matrix row 0 (M[0][0..3])
        addr 12-15   : matrix row 1 (M[1][0..3])
        addr 16-19   : matrix row 2 (M[2][0..3])
        addr 20-23   : matrix row 3 (M[3][0..3])
        addr 32-35   : output y[0..3]

    Each thread i computes:
        1. Load scalar from addr 0           ** ALL threads read same addr **
        2. Load x[0..3] from addr 1-4        ** ALL threads read same 4 addrs **
        3. Load M[i][0..3] from addr 8+i*4   (unique per thread)
        4. dot = M[i][0]*x[0] + M[i][1]*x[1] + M[i][2]*x[2] + M[i][3]*x[3]
        5. y[i] = scalar * dot
        6. Store y[i] to addr 32+i

    With 4 threads, the scalar load gives 4:1 coalescing and each x[k] load
    gives 4:1 coalescing. That's 5 broadcast loads out of 9 total LDRs per
    thread (the 4 matrix element loads are unique per thread).
    """

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")

    program = [
        #                                         ; R13=%blockIdx, R14=%blockDim, R15=%threadIdx
        0b0101_0000_1101_1110,  # MUL R0, R13, R14          ; R0 = blockIdx * blockDim
        0b0011_0000_0000_1111,  # ADD R0, R0, R15           ; R0 = i

        # Load scalar from addr 0 (ALL threads read same address)
        0b1001_0001_0000_0000,  # CONST R1, #0
        0b0111_0001_0001_0000,  # LDR R1, R1                ; R1 = scalar = mem[0] ** BROADCAST **

        # Load x[0] from addr 1 (ALL threads read same address)
        0b1001_0010_0000_0001,  # CONST R2, #1
        0b0111_0010_0010_0000,  # LDR R2, R2                ; R2 = x[0] = mem[1] ** BROADCAST **

        # Load x[1] from addr 2 (ALL threads read same address)
        0b1001_0011_0000_0010,  # CONST R3, #2
        0b0111_0011_0011_0000,  # LDR R3, R3                ; R3 = x[1] = mem[2] ** BROADCAST **

        # Load x[2] from addr 3 (ALL threads read same address)
        0b1001_0100_0000_0011,  # CONST R4, #3
        0b0111_0100_0100_0000,  # LDR R4, R4                ; R4 = x[2] = mem[3] ** BROADCAST **

        # Load x[3] from addr 4 (ALL threads read same address)
        0b1001_0101_0000_0100,  # CONST R5, #4
        0b0111_0101_0101_0000,  # LDR R5, R5                ; R5 = x[3] = mem[4] ** BROADCAST **

        # Compute base address for matrix row: R6 = 8 + i*4
        0b1001_0110_0000_0100,  # CONST R6, #4              ; R6 = 4 (row stride)
        0b0101_0110_0000_0110,  # MUL R6, R0, R6            ; R6 = i * 4
        0b1001_0111_0000_1000,  # CONST R7, #8              ; R7 = 8 (matrix base)
        0b0011_0110_0110_0111,  # ADD R6, R6, R7            ; R6 = 8 + i*4 (row base addr)

        # Load M[i][0]
        0b0111_0111_0110_0000,  # LDR R7, R6                ; R7 = M[i][0]

        # Compute addr for M[i][1]: R8 = R6 + 1
        0b1001_1000_0000_0001,  # CONST R8, #1
        0b0011_1000_0110_1000,  # ADD R8, R6, R8            ; R8 = row_base + 1
        0b0111_1000_1000_0000,  # LDR R8, R8                ; R8 = M[i][1]

        # Compute addr for M[i][2]: R9 = R6 + 2
        0b1001_1001_0000_0010,  # CONST R9, #2
        0b0011_1001_0110_1001,  # ADD R9, R6, R9            ; R9 = row_base + 2
        0b0111_1001_1001_0000,  # LDR R9, R9                ; R9 = M[i][2]

        # Compute addr for M[i][3]: R10 = R6 + 3
        0b1001_1010_0000_0011,  # CONST R10, #3
        0b0011_1010_0110_1010,  # ADD R10, R6, R10          ; R10 = row_base + 3
        0b0111_1010_1010_0000,  # LDR R10, R10              ; R10 = M[i][3]

        # dot = M[i][0]*x[0] + M[i][1]*x[1] + M[i][2]*x[2] + M[i][3]*x[3]
        0b0101_0111_0111_0010,  # MUL R7, R7, R2            ; R7 = M[i][0] * x[0]
        0b0101_1000_1000_0011,  # MUL R8, R8, R3            ; R8 = M[i][1] * x[1]
        0b0101_1001_1001_0100,  # MUL R9, R9, R4            ; R9 = M[i][2] * x[2]
        0b0101_1010_1010_0101,  # MUL R10, R10, R5          ; R10 = M[i][3] * x[3]
        0b0011_0111_0111_1000,  # ADD R7, R7, R8            ; R7 = partial sum
        0b0011_0111_0111_1001,  # ADD R7, R7, R9            ; R7 += M[i][2]*x[2]
        0b0011_0111_0111_1010,  # ADD R7, R7, R10           ; R7 = dot product

        # y[i] = scalar * dot
        0b0101_0111_0001_0111,  # MUL R7, R1, R7            ; R7 = scalar * dot

        # Store to addr 32 + i
        0b1001_1000_0010_0000,  # CONST R8, #32             ; output base
        0b0011_1000_1000_0000,  # ADD R8, R8, R0            ; R8 = 32 + i
        0b1000_0000_1000_0111,  # STR R8, R7                ; mem[32+i] = y[i]

        0b1111_0000_0000_0000,  # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")

    scalar = 3
    x = [1, 2, 1, 2]
    matrix = [
        [1, 0, 0, 0],  # row 0
        [0, 1, 0, 0],  # row 1
        [1, 1, 0, 0],  # row 2
        [0, 0, 1, 1],  # row 3
    ]

    data = [scalar] + x + [0, 0, 0]  # addr 0-7 (pad to 8)
    for row in matrix:
        data += row  # addr 8-23

    threads = 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(40)

    stats = Stats(dut)

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(40)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")

    # Verify: y = scalar * M @ x
    for i in range(4):
        dot = sum(matrix[i][j] * x[j] for j in range(4))
        expected = (scalar * dot) & 0xFF
        result = data_memory.memory[32 + i]
        assert result == expected, f"y[{i}] mismatch: expected {expected}, got {result}"
