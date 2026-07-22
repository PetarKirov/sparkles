// Everything above `---cut---` is type-checked but trimmed from the output.
type User = { id: number; name: string }
const db: Record<number, User> = { 1: { id: 1, name: "Ada" } }
// ---cut---
const user = db[1]
//    ^?
