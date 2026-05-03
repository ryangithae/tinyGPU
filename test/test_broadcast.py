import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.stats import Stats

@cocotb.test()
async def test_broadcast(dut):
    """Broadcast load test: ALL threads load from the SAME address multiple times.

    Every thread does:
        R0 = blockIdx * blockDim + threadIdx   (i)
        R1 = mem[0]   (broadcast load - all threads read addr 0)
        R2 = mem[1]   (broadcast load - all threads read addr 1)
        R3 = mem[2]   (broadcast load - all threads read addr 2)
        R4 = mem[3]   (broadcast load - all threads read addr 3)
        R5 = R1 + R2
        R5 = R5 + R3
        R5 = R5 + R4  (R5 = sum of the 4 broadcast values)
        R6 = R5 * R5  (square the sum)
        addr = 16 + i
        mem[addr] = R6 (store result per thread)

    With 8 threads and 4 threads/block, each LDR has all 4 threads in a block
    reading the exact same address => perfect coalescing opportunity (4 reads
    become 1). There are 4 broadcast loads, so 4x coalescing benefit.
    """

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")

    # Encoding helper:
    # MUL  rd, rs, rt => 0101_rd_rs_rt
    # ADD  rd, rs, rt => 0011_rd_rs_rt
    # LDR  rd, rs     => 0111_rd_rs_0000
    # STR  rs, rt      => 1000_0000_rs_rt
    # CONST rd, imm8  => 1001_rd_imm8
    # RET             => 1111_0000_0000_0000

    program = [
        #                                         ; R13=%blockIdx, R14=%blockDim, R15=%threadIdx
        0b0101_0000_1101_1110,  # MUL R0, R13, R14          ; R0 = blockIdx * blockDim
        0b0011_0000_0000_1111,  # ADD R0, R0, R15           ; R0 = i = blockIdx*blockDim + threadIdx

        # Broadcast loads: all threads read from the same addresses
        0b1001_0001_0000_0000,  # CONST R1, #0              ; addr = 0
        0b0111_0001_0001_0000,  # LDR R1, R1                ; R1 = mem[0]  ** ALL threads read addr 0 **

        0b1001_0010_0000_0001,  # CONST R2, #1              ; addr = 1
        0b0111_0010_0010_0000,  # LDR R2, R2                ; R2 = mem[1]  ** ALL threads read addr 1 **

        0b1001_0011_0000_0010,  # CONST R3, #2              ; addr = 2
        0b0111_0011_0011_0000,  # LDR R3, R3                ; R3 = mem[2]  ** ALL threads read addr 2 **

        0b1001_0100_0000_0011,  # CONST R4, #3              ; addr = 3
        0b0111_0100_0100_0000,  # LDR R4, R4                ; R4 = mem[3]  ** ALL threads read addr 3 **

        # Compute: sum = R1+R2+R3+R4, then square it
        0b0011_0101_0001_0010,  # ADD R5, R1, R2            ; R5 = R1 + R2
        0b0011_0101_0101_0011,  # ADD R5, R5, R3            ; R5 = R5 + R3
        0b0011_0101_0101_0100,  # ADD R5, R5, R4            ; R5 = R5 + R4 = sum
        0b0101_0110_0101_0101,  # MUL R6, R5, R5            ; R6 = sum * sum

        # Store result: mem[16 + i] = R6
        0b1001_0111_0001_0000,  # CONST R7, #16             ; baseC = 16
        0b0011_0111_0111_0000,  # ADD R7, R7, R0            ; R7 = 16 + i
        0b1000_0000_0111_0110,  # STR R7, R6                ; mem[16+i] = R6

        0b1111_0000_0000_0000,  # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        2, 3, 5, 7,  # 4 shared values at addresses 0-3
    ]

    threads = 128

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(24)

    stats = Stats(dut)

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(24)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")

    # Verify: sum = 2+3+5+7 = 17, result = 17*17 = 289, but 8-bit so 289 % 256 = 33
    broadcast_sum = sum(data[0:4])  # 17
    expected = (broadcast_sum * broadcast_sum) & 0xFF  # 289 & 0xFF = 33
    for i in range(threads):
        result = data_memory.memory[16 + i]
        assert result == expected, f"Result mismatch at thread {i}: expected {expected}, got {result}"
