import pc from 'picocolors';

export function greet(name) {
  return `${pc.green('hello')}, ${pc.bold(name)}!`;
}
