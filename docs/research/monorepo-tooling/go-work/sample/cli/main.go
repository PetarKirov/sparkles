// Command cli is the workspace's application module. It imports the sibling
// `greeter` module by its module path; in workspace mode `go.work` resolves
// that import to ../greeter on disk.
package main

import (
	"fmt"

	"example.com/greeter"
)

func main() {
	fmt.Println(greeter.Greet("monorepo"))
}
