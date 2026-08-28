import time
import datetime
import random
import os
LEVELS = ["INFO","INFO","INFO","DEBUG","WARN","ERROR"]
SERVICES = ["orders","payments","auth","catalog"]
MESSAGES = [
    "request completed", "user logged in", "payment authorized",
    "cache miss", "db timeout", "invalid token", "order shipped",
    "retrying upstream", "rate limit hit", "record not found",
]
os.makedirs("/logs", exist_ok=True)
path = "/logs/app.log"
print("log-generator writing to", path, flush=True)
while True:
    ts  = datetime.datetime.utcnow().isoformat() + "Z"
    lvl = random.choice(LEVELS)
    svc = random.choice(SERVICES)
    msg = random.choice(MESSAGES)
    line = f"{ts} {lvl} {svc} - {msg}\n"
    with open(path, "a") as f:
        f.write(line)
    time.sleep(random.uniform(0.3, 1.5))
