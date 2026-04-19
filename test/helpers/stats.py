from .format import format_core_state
from .logger import logger

class Stats:
    def __init__(self, dut):
        self.dut = dut
        self.cycles = 0
        self.num_inst = 0
        self.mem_stall_cycles = 0
        self.execute_cycles = 0
        self.core_stats = {}  # keyed by core index

    def tick(self):
        for core in self.dut.cores:
            core_idx = int(core.i.value)
            if core_idx not in self.core_stats:
                self.core_stats[core_idx] = {
                    "mem_stall_cycles": 0,
                    "execute_cycles": 0,
                    "num_inst": 0,
                    "thread_count": int(str(core.core_instance.thread_count.value), 2)
                }

            state = format_core_state(str(core.core_instance.core_state.value))
            if state == "WAIT":
                self.mem_stall_cycles += 1
                self.core_stats[core_idx]["mem_stall_cycles"] += 1
            elif state in ("EXECUTE", "UPDATE"):
                self.execute_cycles += 1
                self.core_stats[core_idx]["execute_cycles"] += 1
                if state == "UPDATE":
                    thread_count = int(str(core.core_instance.thread_count.value), 2)
                    self.num_inst += thread_count
                    self.core_stats[core_idx]["num_inst"] += thread_count

        self.cycles += 1

    def flush(self):
        num_cores = len(self.core_stats)
        ipc = self.num_inst / self.cycles if self.cycles > 0 else 0.0
        utilization = self.execute_cycles / (self.cycles * num_cores) if self.cycles > 0 else 0.0
        stall_rate = self.mem_stall_cycles / (self.cycles * num_cores) if self.cycles > 0 else 0.0

        logger.stats(
            cycles=self.cycles,
            num_inst=self.num_inst,
            ipc=f"{ipc:.4f}",
            execute_cycles=self.execute_cycles,
            mem_stall_cycles=self.mem_stall_cycles,
            utilization=f"{utilization:.2%}",
            stall_rate=f"{stall_rate:.2%}",
        )

        for core_idx, cs in self.core_stats.items():
            core_ipc = cs["num_inst"] / self.cycles if self.cycles > 0 else 0.0
            core_util = cs["execute_cycles"] / self.cycles if self.cycles > 0 else 0.0
            logger.info(
                f" core {core_idx} "
                f"| threads={cs['thread_count']} "
                f"| inst={cs['num_inst']} "
                f"| ipc={core_ipc:.4f} "
                f"| stall={cs['mem_stall_cycles']} cycles "
                f"| util={core_util:.2%}"
            )