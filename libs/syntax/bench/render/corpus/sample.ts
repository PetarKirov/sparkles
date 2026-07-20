// Representative TypeScript corpus for the sparkles:syntax foreign benchmark
// panel. Original BSL-1.0 code (ours) — a small highlight-event model + HTML
// folder mirroring the D/Python corpora, dense with token classes (types,
// generics, template literals, enums, decorators-in-comment, regex, numbers)
// so TextMate/Pygments/chroma grammars have realistic work.

/** The three shapes a highlight event can take. */
export const enum EventKind {
  Push = 'push',
  Pop = 'pop',
  Span = 'span',
}

export interface Event {
  readonly kind: EventKind;
  readonly label: string;
  readonly start: number;
  readonly end: number;
}

const SGR: Readonly<Record<string, string>> = {
  keyword: 'color:#c586c0',
  string: 'color:#ce9178',
  number: 'color:#b5cea8',
  comment: 'color:#6a9955',
};

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, c => {
    switch (c) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

/** Folds an event stream + source into styled HTML. */
export class HtmlFolder {
  private readonly stack: string[] = [];

  constructor(private readonly source: string) {}

  private style(): string {
    for (let i = this.stack.length - 1; i >= 0; i--) {
      const label = this.stack[i];
      if (label in SGR) return SGR[label];
    }
    return '';
  }

  fold(events: Iterable<Event>): string {
    const out: string[] = ['<pre><code>'];
    for (const ev of events) {
      if (ev.kind === EventKind.Push) {
        this.stack.push(ev.label);
      } else if (ev.kind === EventKind.Pop) {
        this.stack.pop();
      } else {
        const text = escapeHtml(this.source.slice(ev.start, ev.end));
        const style = this.style();
        out.push(style ? `<span style="${style}">${text}</span>` : text);
      }
    }
    out.push('</code></pre>');
    return out.join('');
  }
}

function* spans(
  labels: ReadonlyMap<string, readonly [number, number]>,
): Iterator<Event> {
  const sorted = [...labels.entries()].sort((a, b) => a[1][0] - b[1][0]);
  for (const [label, [start, end]] of sorted) {
    yield { kind: EventKind.Push, label, start, end };
    yield { kind: EventKind.Span, label, start, end };
    yield { kind: EventKind.Pop, label, start, end };
  }
}

export function demo(): string {
  const src = `x = 0xff + 12_000; // the "answer"`;
  const labels = new Map<string, readonly [number, number]>([
    ['number', [4, 8]],
    ['comment', [18, src.length]],
  ]);
  return new HtmlFolder(src).fold({ [Symbol.iterator]: () => spans(labels) });
}

if (typeof require !== 'undefined' && require.main === module) {
  console.log(demo());
}
