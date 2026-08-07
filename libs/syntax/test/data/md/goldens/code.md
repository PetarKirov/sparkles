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
```

:::
