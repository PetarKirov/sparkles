// Ported from @shikijs/twoslash docs (rendererRich showcase): a Readonly<T>
// query, a read-only-assignment error, and a completion list in one snippet.
// @errors: 2540
interface Todo {
  title: string
}

const todo: Readonly<Todo> = {
  title: 'Delete inactive users'.toUpperCase(),
//  ^?
}

todo.title = 'Hello'

Number.parseInt('123', 10)
//      ^|
