#!/usr/bin/env python3

import os
import select
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "Usage: stream_gemini_with_idle_timeout.py <idle-seconds> <log-file> <command> [args...]",
            file=sys.stderr,
        )
        return 2

    idle_seconds = float(sys.argv[1])
    log_file = sys.argv[2]
    command = sys.argv[3:]

    os.makedirs(os.path.dirname(log_file), exist_ok=True)

    with open(log_file, "w", encoding="utf-8") as log_handle:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        assert process.stdout is not None
        last_output_at = time.monotonic()

        while True:
            if process.poll() is not None:
                for remainder in process.stdout:
                    sys.stdout.write(remainder)
                    sys.stdout.flush()
                    log_handle.write(remainder)
                    log_handle.flush()
                return process.returncode or 0

            ready, _, _ = select.select([process.stdout], [], [], idle_seconds)
            if not ready:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

                message = (
                    f"Idle timeout reached after {int(idle_seconds)}s with no new Gemini stream events.\n"
                )
                sys.stdout.write(message)
                sys.stdout.flush()
                log_handle.write(message)
                log_handle.flush()
                return 124

            line = process.stdout.readline()
            if not line:
                continue

            last_output_at = time.monotonic()
            _ = last_output_at
            sys.stdout.write(line)
            sys.stdout.flush()
            log_handle.write(line)
            log_handle.flush()


if __name__ == "__main__":
    raise SystemExit(main())
