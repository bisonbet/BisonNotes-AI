"""Copies an XCTest file, dropping test methods whose bodies match a pattern.

Usage: filter_tests.py <pattern> <source> <destination>

Attributes such as @MainActor on the line above a dropped method go with it.
"""
import re
import sys


def main() -> None:
    pattern, source, destination = sys.argv[1:4]
    lines = open(source, encoding="utf-8").read().split("\n")
    out: list[str] = []
    dropped: list[str] = []
    i = 0
    while i < len(lines):
        match = re.match(r"    (?:@\w+\s+)*func (test\w+)\(", lines[i])
        if match:
            end = i + 1
            while end < len(lines) and lines[end] != "    }":
                end += 1
            if re.search(pattern, "\n".join(lines[i : end + 1])):
                dropped.append(match.group(1))
                while out and re.fullmatch(r"    @\w+", out[-1]):
                    out.pop()
                i = end + 1
                continue
        out.append(lines[i])
        i += 1
    with open(destination, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))
    if dropped:
        print(f"[swift-check] skipped (need Apple frameworks): {', '.join(dropped)}", file=sys.stderr)


if __name__ == "__main__":
    main()
