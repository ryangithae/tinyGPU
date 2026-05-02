import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.stats import Stats


def count_external_reads(dut):
    # Counts top-level data-memory read handshakes for this cycle
    valid = int(dut.data_mem_read_valid.value)
    ready = int(dut.data_mem_read_ready.value)
    return bin(valid & ready).count("1")


@cocotb.test()
async def test_broadcast_load(dut):
    # All 4 threads read the SAME address.
    # Phase-1 coalescer should reduce external reads for the LDR from 4 -> 1.

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b1001000100000000, # CONST R1, #0            ; shared input address
        0b0111001000010000, # LDR   R2, R1            ; load shared value
        0b0011001100101111, # ADD   R3, R2, %threadIdx
        0b1001010000000100, # CONST R4, #4            ; output base
        0b0011010101001111, # ADD   R5, R4, %threadIdx
        0b1000000001010011, # STR   R5, R3
        0b1111000000000000, # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        42,  # shared input at address 0
    ]

    threads = 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(12)

    stats = Stats(dut)
    external_reads = 0

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        external_reads += count_external_reads(dut)
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(12)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")
    logger.info(f"External data-memory reads = {external_reads}")

    expected_results = [42 + tid for tid in range(4)]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 4]
        assert result == expected, f"Broadcast result mismatch at index {i}: expected {expected}, got {result}"


@cocotb.test()
async def test_pairwise_duplicate_load(dut):
    # Threads 0/1 read address 0, threads 2/3 read address 1.
    # Phase-1 coalescer should reduce external reads for the LDR from 4 -> 2.

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b1001000100000010, # CONST R1, #2            ; divisor
        0b0110001011110001, # DIV   R2, %threadIdx, R1 ; pair_idx = threadIdx // 2 => 0,0,1,1
        0b0111001100100000, # LDR   R3, R2            ; load data[pair_idx]
        0b1001010000001000, # CONST R4, #8            ; output base
        0b0011010101001111, # ADD   R5, R4, %threadIdx
        0b1000000001010011, # STR   R5, R3
        0b1111000000000000, # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        10, 20,  # addresses 0 and 1
    ]

    threads = 4

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
    external_reads = 0

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        external_reads += count_external_reads(dut)
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(16)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")
    logger.info(f"External data-memory reads = {external_reads}")

    expected_results = [10, 10, 20, 20]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Pairwise result mismatch at index {i}: expected {expected}, got {result}"


@cocotb.test()
async def test_unique_load_control(dut):
    # Negative-control test:
    # each thread reads a UNIQUE address, so phase-1 coalescing should not help.

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b1001000100000000, # CONST R1, #0
        0b0011001000011111, # ADD   R2, R1, %threadIdx ; addr = threadIdx
        0b0111001100100000, # LDR   R3, R2
        0b1001010000001000, # CONST R4, #8            ; output base
        0b0011010101001111, # ADD   R5, R4, %threadIdx
        0b1000000001010011, # STR   R5, R3
        0b1111000000000000, # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        9, 8, 7, 6,  # unique values at addresses 0..3
    ]

    threads = 4

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
    external_reads = 0

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        external_reads += count_external_reads(dut)
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(16)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")
    logger.info(f"External data-memory reads = {external_reads}")

    expected_results = [9, 8, 7, 6]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Unique-load result mismatch at index {i}: expected {expected}, got {result}"


@cocotb.test()
async def test_double_broadcast_load(dut):
    # All threads read address 0, then all threads read address 1.
    # This checks that the coalescer handles multiple coalescable LDRs in one kernel.

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b1001000100000000, # CONST R1, #0
        0b0111001000010000, # LDR   R2, R1            ; shared value A

        0b1001001100000001, # CONST R3, #1
        0b0111010000110000, # LDR   R4, R3            ; shared value B

        0b0011010100100100, # ADD   R5, R2, R4        ; sum = A + B
        0b0011010101011111, # ADD   R5, R5, %threadIdx

        0b1001011000001000, # CONST R6, #8            ; output base
        0b0011011101101111, # ADD   R7, R6, %threadIdx
        0b1000000001110101, # STR   R7, R5
        0b1111000000000000, # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        30, 12,  # addresses 0 and 1
    ]

    threads = 4

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
    external_reads = 0

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        stats.tick()
        external_reads += count_external_reads(dut)
        format_cycle(dut, stats.cycles)

        await RisingEdge(dut.clk)

    data_memory.display(16)
    stats.flush()
    logger.info(f"Completed in {stats.cycles} cycles")
    logger.info(f"External data-memory reads = {external_reads}")

    expected_results = [42 + tid for tid in range(4)]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Double-broadcast mismatch at index {i}: expected {expected}, got {result}"