// Showcases MARKDOWN in hover/query docs and @tag values — the reason the
// overlay routes `docs` through the `sparkles:syntax` MdDoc → HTML emitter.
// Every construct below (bold, inline `code`, a bullet list, a fenced block,
// links, and the @param/@returns/@see tag chips) round-trips into the popup.

/**
 * Computes the **ultimate answer** to `life`, the universe, and everything.
 *
 * The procedure, in short:
 *
 * - consult the `Deep Thought` computer
 * - wait ~7.5 million years
 * - read off the result
 *
 * ```ts
 * const answer = compute(true) // 42
 * ```
 *
 * See the [reference](https://example.com/hitchhikers) for the long version.
 *
 * @param verbose when set, logs the `progress` at each step
 * @returns the _magic_ number every question resolves to
 * @see [The Hitchhiker's Guide](https://example.com/guide) — a markdown link
 * @see <https://example.com/towel> — an autolink
 */
function compute(verbose?: boolean): number {
  return 42
}

const answer = compute(true)
//    ^?
