#!/usr/bin/env python3
"""Writes the files scripts/bench-terminal.sh cats into a terminal. Deterministic, so runs compare.

  python3 -I scripts/bench-terminal-workloads.py <dir>

ascii.txt    plain 80-column text
sgr.txt      every word in its own color: 256-color, truecolor, bold, underline, reset
unicode.txt  CJK, emoji (some with variation selectors and ZWJ), combining marks, mixed with ASCII
wrap.txt     lines of 1,000 to 8,000 characters, so nearly every row is a wrapped continuation
agent.txt    shaped like a TUI agent's long run (Claude Code and Codex draw with Ink/ratatui): a live
             region at the bottom redrawn every frame by moving the cursor up, erasing and rewriting
             lines inside synchronized-update brackets, a spinner and a timer, and finished messages
             committed above it into scrollback, with colored diffs and tool output.
"""
import os
import random
import sys

MB = 1024 * 1024
WORDS = ("the quick brown fox jumps over lazy dog terminal render parse buffer scroll cursor line "
         "agent tool call result diff file read write edit search build test pass fail swift").split()


def ascii_file(path, size):
    rnd = random.Random(1)
    with open(path, "w") as out:
        written = 0
        while written < size:
            line = []
            length = 0
            while length < 78:
                word = rnd.choice(WORDS)
                line.append(word)
                length += len(word) + 1
            text = " ".join(line)[:79] + "\n"
            out.write(text)
            written += len(text)


def sgr_file(path, size):
    rnd = random.Random(2)
    with open(path, "w") as out:
        written = 0
        while written < size:
            parts = []
            for _ in range(12):
                kind = rnd.randrange(4)
                word = rnd.choice(WORDS)
                if kind == 0:
                    parts.append(f"\x1b[38;5;{rnd.randrange(256)}m{word}")
                elif kind == 1:
                    parts.append(f"\x1b[38;2;{rnd.randrange(256)};{rnd.randrange(256)};{rnd.randrange(256)}m{word}")
                elif kind == 2:
                    parts.append(f"\x1b[1;4;48;5;{rnd.randrange(256)}m{word}\x1b[22;24m")
                else:
                    parts.append(f"\x1b[0m{word}")
            text = " ".join(parts) + "\x1b[0m\n"
            out.write(text)
            written += len(text.encode())


def unicode_file(path, size):
    rnd = random.Random(3)
    cjk = "终端渲染速度测试中文字符宽度日本語のテキスト한국어텍스트漢字表示確認"
    emoji = ["😀", "🚀", "✅", "❌", "🔥", "👍🏽", "👨‍👩‍👧", "❤️", "🇯🇵", "⚠️", "🧪", "📦"]
    combining = ["é", "ñ", "ü", "ẽ", "á", "ö"]
    with open(path, "w", encoding="utf-8") as out:
        written = 0
        while written < size:
            parts = []
            for _ in range(10):
                kind = rnd.randrange(4)
                if kind == 0:
                    parts.append("".join(rnd.choice(cjk) for _ in range(rnd.randrange(2, 8))))
                elif kind == 1:
                    parts.append(rnd.choice(emoji))
                elif kind == 2:
                    parts.append(rnd.choice(WORDS) + rnd.choice(combining))
                else:
                    parts.append(rnd.choice(WORDS))
            text = " ".join(parts) + "\n"
            out.write(text)
            written += len(text.encode())


def wrap_file(path, size):
    rnd = random.Random(4)
    with open(path, "w") as out:
        written = 0
        while written < size:
            target = rnd.randrange(1000, 8000)
            line = []
            length = 0
            while length < target:
                word = rnd.choice(WORDS)
                line.append(word)
                length += len(word) + 1
            text = " ".join(line) + "\n"
            out.write(text)
            written += len(text)


def agent_file(path, frames):
    rnd = random.Random(5)
    spinner = "·✢✳∗✻✽"
    esc = "\x1b"
    out = open(path, "w", encoding="utf-8")
    live = 0  # rows the live region took last frame

    def erase_live():
        # What Ink does: erase this line, then up one and erase, for every line it drew.
        if live == 0:
            return ""
        return (f"{esc}[2K{esc}[1A" * (live - 1)) + f"{esc}[2K{esc}[G"

    def message():
        kind = rnd.randrange(4)
        if kind == 0:
            words = " ".join(rnd.choice(WORDS) for _ in range(rnd.randrange(20, 120)))
            return f"{esc}[38;2;215;119;87m⏺{esc}[39m {words}\n\n"
        if kind == 1:
            name = rnd.choice(["Read", "Bash", "Edit", "Grep"])
            arg = "/".join(rnd.choice(WORDS) for _ in range(4)) + ".swift"
            body = "".join(f"  {esc}[2m⎿{esc}[22m  {rnd.choice(WORDS)} {rnd.choice(WORDS)} {rnd.randrange(1000)}\n" for _ in range(rnd.randrange(1, 6)))
            return f"{esc}[32m⏺{esc}[39m {esc}[1m{name}{esc}[22m({arg})\n{body}\n"
        if kind == 2:
            rows = []
            for n in range(rnd.randrange(4, 24)):
                text = " ".join(rnd.choice(WORDS) for _ in range(rnd.randrange(3, 12)))
                if rnd.random() < 0.4:
                    rows.append(f"      {n + 100} {esc}[48;2;34;92;43m{esc}[38;2;255;255;255m+ {text}{esc}[K{esc}[0m\n")
                elif rnd.random() < 0.3:
                    rows.append(f"      {n + 100} {esc}[48;2;122;41;54m{esc}[38;2;255;255;255m- {text}{esc}[K{esc}[0m\n")
                else:
                    rows.append(f"      {n + 100}   {esc}[38;5;{rnd.randrange(16, 231)}m{text}{esc}[0m\n")
            return f"{esc}[32m⏺{esc}[39m {esc}[1mUpdate{esc}[22m(Sources/App.swift)\n" + "".join(rows) + "\n"
        return f"{esc}[2m> {esc}[22m" + " ".join(rnd.choice(WORDS) for _ in range(rnd.randrange(5, 30))) + "\n\n"

    def live_region(frame):
        tokens = frame * 13
        rows = [
            f"{esc}[38;2;215;119;87m{spinner[frame % len(spinner)]}{esc}[39m {esc}[1mWorking…{esc}[22m {esc}[2m({frame // 10}s · ↓ {tokens} tokens · esc to interrupt){esc}[22m",
            "",
            f"{esc}[2m╭" + "─" * 100 + f"╮{esc}[22m",
            f"{esc}[2m│{esc}[22m > " + " " * 97 + f"{esc}[2m│{esc}[22m",
            f"{esc}[2m╰" + "─" * 100 + f"╯{esc}[22m",
            f"  {esc}[2m? for shortcuts{esc}[22m" + " " * 60 + f"{esc}[38;5;114m◯ IDE connected{esc}[39m",
        ]
        return rows

    for frame in range(frames):
        chunk = [f"{esc}[?2026h", erase_live()]
        if frame % 8 == 0:
            chunk.append(message())
        rows = live_region(frame)
        chunk.append("\n".join(rows))
        chunk.append(f"{esc}[?2026l")
        live = len(rows)
        out.write("".join(chunk))
    out.write(erase_live() + "done\n")
    out.close()


def main():
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    jobs = {
        "ascii.txt": lambda p: ascii_file(p, 64 * MB),
        "sgr.txt": lambda p: sgr_file(p, 64 * MB),
        "unicode.txt": lambda p: unicode_file(p, 32 * MB),
        "wrap.txt": lambda p: wrap_file(p, 64 * MB),
        "agent.txt": lambda p: agent_file(p, 40_000),
    }
    for name, make in jobs.items():
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            make(path)
        print(f"{name} {os.path.getsize(path) / MB:.1f} MB")


if __name__ == "__main__":
    main()
