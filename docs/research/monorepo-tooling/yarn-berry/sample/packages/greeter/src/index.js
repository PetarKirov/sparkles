/**
 * Build a friendly greeting. This is the workspace that `@acme/cli`
 * depends on locally via the `workspace:^` protocol.
 *
 * @param {string} name
 * @returns {string}
 */
export function greet(name) {
  return `Hello, ${name}!`;
}
