# Code fences

Plain (no language):

```
plain preformatted text
    indented line
```

With a language:

```d
import std.stdio;

void main()
{
    writeln("hello");
}
```

With a label:

```d [example.d]
enum answer = 42;
```

Short and long lines:

```sh
x=1
printf '%s\n' "a deliberately long command line that exceeds typical widths to exercise horizontal overflow handling inside the panel"
```

Empty body:

```d
```

A code group:

::: code-group

```d [app.d]
void main() {}
```

```sh [build]
dub build
dub test
dub run -- --help
```

:::

A code group with five tabs:

::: code-group

```d [main.d]
import std.stdio;
import std.algorithm : map, filter, sum;
import std.range : iota;

int square(int n)
{
    return n * n;
}

bool isEven(int n)
{
    return n % 2 == 0;
}

void main()
{
    auto total = iota(1, 11)
        .filter!isEven
        .map!square
        .sum;
    writeln("sum of squares of even 1..10: ", total);
    foreach (i; 0 .. 5)
        writefln("  step %s", i);
}
```

```c [main.c]
#include <stdio.h>
#include <stdlib.h>

static int square(int n)
{
    return n * n;
}

static int is_even(int n)
{
    return n % 2 == 0;
}

int main(void)
{
    int total = 0;
    int i;

    for (i = 1; i <= 10; i++)
    {
        if (is_even(i))
            total += square(i);
    }

    printf("sum of squares of even 1..10: %d\n", total);
    for (i = 0; i < 5; i++)
        printf("  step %d\n", i);

    return EXIT_SUCCESS;
}
```

```rs [main.rs]
fn square(n: i32) -> i32 {
    n * n
}

fn is_even(n: i32) -> bool {
    n % 2 == 0
}

fn main() {
    let total: i32 = (1..=10)
        .filter(|&n| is_even(n))
        .map(square)
        .sum();

    println!("sum of squares of even 1..10: {}", total);

    for i in 0..5 {
        println!("  step {}", i);
    }

    let words = ["alpha", "beta", "gamma"];
    for (idx, word) in words.iter().enumerate() {
        println!("  word[{}] = {}", idx, word);
    }
}
```

```go [main.go]
package main

import "fmt"

func square(n int) int {
	return n * n
}

func isEven(n int) bool {
	return n%2 == 0
}

func main() {
	total := 0
	for i := 1; i <= 10; i++ {
		if isEven(i) {
			total += square(i)
		}
	}

	fmt.Printf("sum of squares of even 1..10: %d\n", total)
	for i := 0; i < 5; i++ {
		fmt.Printf("  step %d\n", i)
	}

	words := []string{"alpha", "beta", "gamma"}
	for idx, word := range words {
		fmt.Printf("  word[%d] = %s\n", idx, word)
	}
}
```

```py [main.py]
def square(n: int) -> int:
    return n * n


def is_even(n: int) -> bool:
    return n % 2 == 0


def main() -> None:
    total = sum(square(n) for n in range(1, 11) if is_even(n))
    print(f"sum of squares of even 1..10: {total}")

    for i in range(5):
        print(f"  step {i}")

    words = ["alpha", "beta", "gamma"]
    for idx, word in enumerate(words):
        print(f"  word[{idx}] = {word}")

    # A few more lines so the body stays tall in the panel.
    flags = {"verbose": True, "dry_run": False}
    for key, value in flags.items():
        print(f"  flag {key}={value}")


if __name__ == "__main__":
    main()
```

:::
