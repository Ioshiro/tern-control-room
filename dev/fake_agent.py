"""Control Room dev helper: a stand-in agent.

Reads one prompt per line, reports "working" with OSC 9;4 while it pretends to
work, and pauses for input (OSC 9;4 state 4, Tern's waiting_input) when the
prompt contains "ask". Set it as the agent command:

    python -u <path>/dev/fake_agent.py
"""

import sys
import time

ESC = "\x1b"


def progress(state: int) -> None:
    # OSC 9;4;<state>;<value>: 1 working, 4 paused, 0 clear.
    sys.stdout.write(f"{ESC}]9;4;{state};50\x07")
    sys.stdout.flush()


print("fake agent ready")
while True:
    sys.stdout.write("> ")
    sys.stdout.flush()
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    progress(1)
    print(f"working on: {line}")
    time.sleep(4)
    if "ask" in line:
        progress(4)
        print("need your input (y/n)?")
        sys.stdin.readline()
    progress(0)
    print(f"done: {line}")
