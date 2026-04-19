import datetime
import os

class Logger:
    def __init__(self, level="debug"):
        impl = os.environ.get("TINYGPU_IMPL", "base")
        test = os.environ.get("TINYGPU_TEST", "unknown").replace("test_", "")
        timestamp = datetime.datetime.now().strftime('%m%d_%H%M%S')
        self.filename = f"test/logs/log_{impl}_{test}_{timestamp}.txt"
        self.level = level

    def debug(self, *messages):
        if self.level == "debug":
            self.info(*messages)

    def info(self, *messages):
        full_message = ' '.join(str(message) for message in messages)
        with open(self.filename, "a") as log_file:
            log_file.write(full_message + "\n")
    
    def stats(self, **metrics):
        self.info("--------------------------------------------")
        self.info(" STATS                                      ")
        self.info("--------------------------------------------")
        for key, value in metrics.items():
            self.info(f" {key:<12} = {value}")
        self.info("--------------------------------------------")

logger = Logger(level="debug")