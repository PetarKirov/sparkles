# Representative Python corpus for the sparkles:syntax foreign benchmark panel.
# Original BSL-1.0 code (ours) — a small, self-contained event-stream folder that
# mirrors the shape of the D corpus (comments, strings, numbers, classes,
# decorators, comprehensions, f-strings) so highlighters have realistic work.
"""A tiny highlight-event model and an ANSI folder, in pure Python.

The point is not correctness but *texture*: enough distinct token classes on
every line that a TextMate/Pygments/chroma grammar has something to colour.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Iterable, Iterator


class EventKind(Enum):
    """The three shapes a highlight event can take."""

    PUSH = auto()
    POP = auto()
    SPAN = auto()


@dataclass(frozen=True, slots=True)
class Event:
    kind: EventKind
    label: str = ""
    start: int = 0
    end: int = 0

    @property
    def length(self) -> int:
        return max(0, self.end - self.start)

    def __str__(self) -> str:  # noqa: D105
        return f"<{self.kind.name} {self.label!r} {self.start}:{self.end}>"


SGR = {
    "keyword": "\x1b[35m",
    "string": "\x1b[32m",
    "number": "\x1b[33m",
    "comment": "\x1b[90m",
}
RESET = "\x1b[0m"


@dataclass
class Folder:
    """Folds an event stream + source into styled ANSI bytes."""

    source: str
    _stack: list[str] = field(default_factory=list)

    def _style(self) -> str:
        for label in reversed(self._stack):
            if label in SGR:
                return SGR[label]
        return ""

    def fold(self, events: Iterable[Event]) -> str:
        out: list[str] = []
        for ev in events:
            if ev.kind is EventKind.PUSH:
                self._stack.append(ev.label)
            elif ev.kind is EventKind.POP:
                if self._stack:
                    self._stack.pop()
            else:
                text = self.source[ev.start : ev.end]
                style = self._style()
                out.append(f"{style}{text}{RESET}" if style else text)
        return "".join(out)


def spans(source: str, labels: dict[str, tuple[int, int]]) -> Iterator[Event]:
    """Yield PUSH/SPAN/POP triples for each labelled slice, in order."""
    for label, (start, end) in sorted(labels.items(), key=lambda kv: kv[1][0]):
        yield Event(EventKind.PUSH, label, start, end)
        yield Event(EventKind.SPAN, label, start, end)
        yield Event(EventKind.POP, label, start, end)


def demo() -> str:
    src = 'x = 0xFF + 12_000  # comment: the "answer"'
    labels = {
        "number": (4, 8),
        "comment": (19, len(src)),
    }
    folded = Folder(src).fold(spans(src, labels))
    total = sum(ev.length for ev in spans(src, labels) if ev.kind is EventKind.SPAN)
    return f"{folded}\n-- highlighted {total} bytes across {len(labels)} spans --"


if __name__ == "__main__":
    print(demo())
