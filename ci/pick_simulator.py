import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
phones = []
for runtime, items in devices.items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(map(int, match[1].split("-")))
    for device in items:
        name = device["name"]
        if device.get("isAvailable") and name.startswith("iPhone"):
            rank = (version, "--promax" in sys.argv and "Pro Max" in name)
            phones.append((rank, device["udid"], name))
if not phones:
    sys.exit("No available iPhone simulator")
_, udid, name = max(phones, key=lambda phone: phone[0])
print(udid)
print(f"Simulator: {name}", file=sys.stderr)
