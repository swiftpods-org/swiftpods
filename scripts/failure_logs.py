#!/usr/bin/env python3
"""Show bounded failure context from verification logs, retaining early errors."""

from reporting import ROOT, failure_excerpt


def main():
    for path in sorted((ROOT / "test-results").glob("*.log")):
        excerpt = failure_excerpt(path.read_text(errors="replace"))
        if excerpt:
            print(str(path), flush=True)
            print(excerpt, flush=True)


if __name__ == "__main__":
    main()
