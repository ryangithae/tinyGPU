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

    threads = 128

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
