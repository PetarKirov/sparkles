// JSDoc on a symbol renders as documentation inside its hover popup.
/**
 * Adds two numbers together.
 * @param a the first addend
 * @param b the second addend
 * @returns their sum
 */
function add(a: number, b: number) {
  return a + b
}

const total = add(1, 2)
//    ^?
