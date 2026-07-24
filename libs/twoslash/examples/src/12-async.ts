// @target: esnext
// @module: esnext
// Inferred Promise types surface through async/await queries.
async function fetchUser(id: number) {
  return { id, name: "Ada" }
}

const user = await fetchUser(1)
//    ^?
