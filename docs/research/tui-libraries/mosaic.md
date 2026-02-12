# Mosaic (Kotlin)

Jetpack Compose's compiler plugin and reactive runtime, retargeted from Android views to terminal ANSI output.

| Attribute     | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| Language      | Kotlin (Multiplatform)                                             |
| Repository    | <https://github.com/JakeWharton/mosaic>                            |
| License       | Apache 2.0                                                         |
| Author        | Jake Wharton                                                       |
| First release | June 2021                                                          |
| Latest        | 0.18.0 (2025)                                                      |
| Platforms     | JVM, Linux x64, macOS ARM/x64, Windows x64, JS (experimental)      |
| Paradigm      | Declarative reactive UI with compiler-plugin-powered recomposition |

---

## Overview

Mosaic is a Kotlin library that brings the Jetpack Compose programming model to terminal user interfaces. Rather than reimplementing Compose's reactive semantics from scratch, Mosaic uses the **actual Compose compiler plugin and runtime** -- the same compiler infrastructure that powers Android's Jetpack Compose and JetBrains' Compose Multiplatform -- and retargets it to produce ANSI-encoded terminal output instead of Android views or desktop windows.

The core insight is that Compose is not fundamentally an Android UI framework. It is a general-purpose compiler and runtime for **state tracking and tree manipulation**. The compiler plugin transforms `@Composable` functions into incremental tree-building code. The runtime maintains a slot table of composition state, observes snapshot state for changes, and triggers minimal recomposition when state mutates. Mosaic supplies a custom `Applier` that maps the abstract composition tree to a grid of styled text pixels, which are then rendered as ANSI escape sequences to stdout.

Mosaic was created by Jake Wharton, a well-known figure in the Android development community and a member of Google's Android team. The project draws direct inspiration from [Ink](https://github.com/vadimdemedes/ink), the React-based terminal UI library for JavaScript. Where Ink proves that React's reconciliation model works for terminals, Mosaic proves the same for Compose's compiler-driven recomposition model -- with the added benefit that recomposition decisions happen at compile time rather than at runtime through virtual DOM diffing.

The library has evolved significantly since its 2021 debut as a JVM-only experiment. Version 0.4.0 (2023) introduced Kotlin Multiplatform support across Linux, macOS, Windows, and experimental JS. Version 0.15.0 added a `mosaic-animation` module. Version 0.17.0 overhauled terminal integration with a custom terminal parsing library, enabling theme detection and focus awareness.

---

## Architecture

Mosaic's architecture is best understood as four layers: the **compiler plugin** that transforms source code, the **runtime** that manages composition state, the **applier** that builds a terminal node tree, and the **renderer** that converts that tree to ANSI output.

### Compose Compiler Plugin

The Compose compiler plugin is a Kotlin compiler plugin (originally from Google, now maintained by JetBrains) that transforms `@Composable` functions at compile time. This is genuine **metaprogramming** -- the plugin rewrites function signatures and bodies to thread composition context, insert change-detection guards, and generate slot-table management code.

When you write:

```kotlin
@Composable
fun Greeting(name: String) {
    Text("Hello, $name!")
}
```

The compiler plugin transforms this into code that roughly:

1. Receives a hidden `Composer` parameter and a change-tracking bitmask (`$changed`).
2. Checks whether `name` has actually changed since the last composition by comparing against the value stored in the slot table.
3. If `name` is unchanged, **skips** the function body entirely (the function is "skippable").
4. If `name` has changed, re-executes the body, updating the slot table and emitting tree operations.

This is fundamentally different from React's virtual DOM diffing. There is no diff at runtime. The compiler has already inserted the exact comparison checks needed, so the runtime only re-executes functions whose inputs have demonstrably changed. This is what makes Compose's recomposition model so efficient.

### Slot Table

The slot table is the runtime data structure that stores the composition's state. It is a flat, gap-buffer-style array that records:

- Which `@Composable` functions were called and in what order (the **group** structure).
- The parameter values passed to each function (for skip-checking).
- State objects created via `remember { ... }` and `mutableStateOf(...)`.
- The structural identity of each node (positional memoization).

The slot table enables Compose to "remember" the previous composition and make surgical updates rather than rebuilding the entire tree.

### Recomposition

Recomposition is the process of re-executing `@Composable` functions when their inputs change. Key properties:

- **Incremental**: Only functions whose read state has changed are re-executed.
- **Positional memoization**: The identity of a composable call is determined by its position in the call tree (augmented by optional `key` calls), not by an explicit ID.
- **Idempotent**: Composable functions must be side-effect-free with respect to the composition. Side effects are channeled through `LaunchedEffect`, `DisposableEffect`, and similar APIs.
- **Concurrent-safe**: The snapshot system ensures that recomposition reads a consistent view of state.

### Snapshot System

Compose's snapshot system provides **observable state** that automatically triggers recomposition. When you write:

```kotlin
var count by remember { mutableIntStateOf(0) }
```

The `mutableIntStateOf` creates a state object backed by the snapshot system. During composition, the runtime records which state objects each `@Composable` function reads. When a state object is written to, the runtime knows exactly which functions need to recompose -- no manual subscriptions, no explicit invalidation.

The snapshot system also provides **isolation**: state changes are committed atomically, preventing torn reads during recomposition.

### Applier: MosaicNodeApplier

The `Applier` is the bridge between Compose's abstract composition and the concrete output format. In Android Compose, the applier inserts `LayoutNode` objects into the Android view hierarchy. In Mosaic, the `MosaicNodeApplier` inserts `MosaicNode` objects into a terminal node tree.

```
Compose Runtime  --[Applier]-->  MosaicNode tree  --[Layout]-->  TextSurface  --[Render]-->  ANSI string
```

The `MosaicNodeApplier` extends `AbstractApplier<MosaicNode>` and manages bottom-up insertion and structural changes (insertions, removals, moves) on the node tree.

### Frame-Based Rendering

Mosaic renders the composition to the terminal in a frame-based loop:

1. A frame clock provides timing signals.
2. Keyboard events are drained and routed to the node tree.
3. The runtime applies any pending recompositions.
4. **Layout phase**: `performLayout()` measures and positions all nodes.
5. **Draw phase**: `performDraw()` renders nodes onto a `TextSurface` (a grid of `TextPixel` objects).
6. **Output phase**: The `TextSurface` is converted to an ANSI string and written to stdout.

The rendering uses **snapshot observers** to track which state objects are read during layout and draw, so these phases are also incrementally re-executed only when relevant state changes.

---

## Terminal Backend

Mosaic renders to stdout using ANSI escape sequences. The ANSI subsystem supports multiple color levels detected at runtime:

| Level       | Description                             |
| ----------- | --------------------------------------- |
| `NONE`      | No color support                        |
| `ANSI16`    | 16 standard colors (codes 30-37, 90-97) |
| `ANSI256`   | 256-color palette (code 5;N)            |
| `TRUECOLOR` | 24-bit RGB (code 2;R;G;B)               |

### Control Sequences

The rendering system uses several ANSI/CSI control sequences:

- **Synchronized output** (mode 2026): Wraps each frame in begin/end markers to prevent flicker on terminals that support it.
- **Clear line** (`CSI K`): Erases previously drawn rows.
- **Clear display** (`CSI J`): Used when static content is emitted, to avoid positioning ambiguity.
- **Cursor positioning**: Moves the cursor to overwrite previous frame output in place.

### Rendering Modes

Mosaic provides two entry points with different output strategies:

**`runMosaic` (interactive mode)**: A suspend function that sets up the terminal, enables raw mode for keyboard input, and renders frames interactively. Each frame overwrites the previous frame's output using cursor movement and line clearing. This is the mode for interactive applications like games or dashboards.

```kotlin
fun main() = runMosaicMain {
    // Interactive composable content
}
```

**`runMosaicBlocking` (static/batch mode)**: Used when output should be appended rather than redrawn. Suited for command-line tools that produce progressive output (like test runners). Supports a `NonInteractivePolicy` parameter for environments without a TTY:

```kotlin
fun main() {
    runMosaicBlocking(onNonInteractive = Ignore) {
        // Content that appends to terminal
    }
}
```

### Non-Interactive Policies

When no TTY is available, Mosaic offers several fallback strategies:

- `Exit` -- terminate with an error message.
- `Throw` -- raise an exception.
- `Return` -- return false immediately.
- `Ignore` -- use a stub terminal with no capabilities.
- `AssumeAndIgnore` -- skip TTY detection entirely.

### Rendering Optimization

The `AnsiRendering` implementation reuses a `StringBuilder` buffer across frames, tracks the previous render height to clear stale lines, and emits ANSI style codes only when pixel attributes change from one cell to the next. This differential encoding minimizes the bytes written per frame.

---

## Layout System

Mosaic's layout system mirrors Jetpack Compose's layout model, adapted for a character grid. Dimensions are measured in **character cells** rather than pixels.

### Core Layout Composables

**`Row`** -- arranges children horizontally:

```kotlin
@Composable
public fun Row(
    modifier: Modifier = Modifier,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    verticalAlignment: Alignment.Vertical = Alignment.Top,
    content: @Composable RowScope.() -> Unit,
)
```

**`Column`** -- arranges children vertically:

```kotlin
@Composable
public fun Column(
    modifier: Modifier = Modifier,
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    content: @Composable ColumnScope.() -> Unit,
)
```

**`Box`** -- stacks children on top of each other (z-axis layering):

```kotlin
@Composable
public fun Box(
    modifier: Modifier = Modifier,
    contentAlignment: Alignment = Alignment.TopStart,
    propagateMinConstraints: Boolean = false,
    content: @Composable BoxScope.() -> Unit,
)
```

### Arrangement and Alignment

Arrangements control how children are distributed within the available space:

| Arrangement      | Pattern     | Description                     |
| ---------------- | ----------- | ------------------------------- |
| `Start` / `Top`  | `123####`   | Pack toward the start           |
| `End` / `Bottom` | `####123`   | Pack toward the end             |
| `Center`         | `##123##`   | Cluster in the middle           |
| `SpaceBetween`   | `1##2##3`   | Even spacing, no outer edges    |
| `SpaceEvenly`    | `#1#2#3#`   | Equal gaps including boundaries |
| `SpaceAround`    | `#1##2##3#` | Half-spacing at edges           |
| `spacedBy(n)`    | Fixed `n`   | Fixed spacing between children  |

Alignments position content within available space using a bias system where -1 is start/top, 0 is center, and 1 is end/bottom. Nine 2D alignments (`TopStart`, `TopCenter`, ..., `BottomEnd`) and six 1D alignments are provided.

### Layout Modifiers

Modifiers form a chain that wraps around a composable, transforming its layout, drawing, or input behavior:

```kotlin
Modifier
    .width(20)
    .height(10)
    .padding(left = 1, top = 1, right = 1, bottom = 1)
    .background(Color.Blue)
```

Key size modifiers:

| Modifier                  | Effect                                             |
| ------------------------- | -------------------------------------------------- |
| `width(n)` / `height(n)`  | Set preferred dimension (constraints may override) |
| `size(w, h)`              | Set both dimensions                                |
| `requiredWidth(n)`        | Enforce exact width regardless of constraints      |
| `fillMaxWidth(fraction)`  | Fill available width (0.0 to 1.0)                  |
| `fillMaxHeight(fraction)` | Fill available height                              |
| `fillMaxSize(fraction)`   | Fill both dimensions                               |
| `wrapContentWidth()`      | Measure at desired size with alignment             |
| `defaultMinSize(w, h)`    | Minimum only when otherwise unconstrained          |

Other modifiers:

| Modifier               | Effect                                        |
| ---------------------- | --------------------------------------------- |
| `padding(...)`         | Add padding (per-side, axis-wise, or uniform) |
| `offset(x, y)`         | Displace without changing layout size         |
| `offset { IntOffset }` | Dynamic offset evaluated during placement     |
| `background(color)`    | Fill background with color behind content     |
| `drawBehind { ... }`   | Custom drawing behind content                 |

### Custom Layout

The `Layout` composable allows fully custom measurement and placement:

```kotlin
@Composable
public fun Layout(
    content: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    measurePolicy: MeasurePolicy,
)
```

A `MeasurePolicy` receives a list of `Measurable` children and `Constraints`, and returns a `MeasureResult` specifying the layout's width, height, and child placements:

```kotlin
@Composable
fun CenteredOverlay(content: @Composable () -> Unit) {
    Layout(content) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints) }
        val width = placeables.maxOf { it.width }
        val height = placeables.sumOf { it.height }
        layout(width, height) {
            var y = 0
            placeables.forEach { placeable ->
                placeable.place((width - placeable.width) / 2, y)
                y += placeable.height
            }
        }
    }
}
```

### Non-Trivial Layout Example

A dashboard with a bordered world containing a movable entity:

```kotlin
@Composable
fun Dashboard(x: Int, y: Int) {
    Column {
        Text("Position: $x, $y")
        Spacer(Modifier.height(1))
        Row(horizontalArrangement = Arrangement.spacedBy(2)) {
            // Stats panel
            Column(Modifier.width(15)) {
                Text("HP:  100/100", color = Color.Green)
                Text("MP:   45/80", color = Color.Blue)
                Text("Gold: 1234", color = Color.Yellow)
            }
            // Game world with border
            Box(
                modifier = Modifier
                    .drawBehind {
                        drawRect('*', drawStyle = DrawStyle.Stroke(1))
                    }
                    .padding(1)
                    .size(20, 10),
            ) {
                Text("@", modifier = Modifier.offset { IntOffset(x, y) })
            }
        }
    }
}
```

---

## Widget / Component System

In Mosaic, **`@Composable` functions are the components**. There is no separate widget class hierarchy. Any function annotated with `@Composable` participates in the composition, can hold state, and composes with other composables.

### Built-in Composables

**`Text`** -- the primary content primitive:

```kotlin
@Composable
public fun Text(
    value: String,
    modifier: Modifier = Modifier,
    color: Color = Color.Unspecified,
    background: Color = Color.Unspecified,
    textStyle: TextStyle = TextStyle.Unspecified,
    underlineStyle: UnderlineStyle = UnderlineStyle.Unspecified,
    underlineColor: Color = Color.Unspecified,
)
```

An `AnnotatedString` overload supports inline styled spans for mixed formatting within a single text block.

**`Spacer`** -- empty space whose size is controlled by modifiers:

```kotlin
Spacer(Modifier.height(1))  // Blank line
Spacer(Modifier.size(5, 2)) // 5x2 empty block
```

**`Filler`** -- fills its area with a repeated character:

```kotlin
Filler('=', modifier = Modifier.fillMaxWidth().height(1), foreground = Color.Cyan)
```

**`Row`**, **`Column`**, **`Box`** -- layout composables (see Layout System above).

### Custom Composables

Any `@Composable` function is a reusable component:

```kotlin
@Composable
fun StatusBadge(label: String, isActive: Boolean) {
    val bg = if (isActive) Color.Green else Color.Red
    val symbol = if (isActive) "ON " else "OFF"
    Row {
        Text(
            symbol,
            modifier = Modifier.background(bg).padding(horizontal = 1),
            color = Color.Black,
        )
        Text(" $label")
    }
}
```

### State: `remember` and `mutableStateOf`

Local state survives recomposition via `remember`:

```kotlin
@Composable
fun Counter() {
    var count by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            count++
        }
    }

    Text("Count: $count")
}
```

When `count` is incremented, only the `Text("Count: $count")` call recomposes -- not the entire function if the compiler determines other parts are unaffected.

### Side Effects: `LaunchedEffect`

`LaunchedEffect` launches a coroutine scoped to the composition. It restarts when its key changes and cancels when the composable leaves the composition:

```kotlin
@Composable
fun Timer(running: Boolean) {
    var elapsed by remember { mutableIntStateOf(0) }

    LaunchedEffect(running) {
        while (running) {
            delay(1000)
            elapsed++
        }
    }

    Text("Elapsed: ${elapsed}s")
}
```

### StaticEffect

`StaticEffect` renders content once and emits it as permanent output above the dynamic section. It composes its content, measures, draws, and logs the result, then never recomposes:

```kotlin
@Composable
fun Log(entries: List<String>) {
    entries.forEach { entry ->
        StaticEffect {
            Text(entry)
        }
    }
}
```

This is how Mosaic's jest sample implements scrolling log output above a live progress bar.

---

## Styling

### TextStyle

`TextStyle` is a value class backed by a bitmask, supporting combinable styles:

| Style           | Description                |
| --------------- | -------------------------- |
| `Bold`          | Bold weight                |
| `Dim`           | Dimmed/faint               |
| `Italic`        | Italic                     |
| `Strikethrough` | Strikethrough line         |
| `Invert`        | Swap foreground/background |

Styles compose via the `+` operator:

```kotlin
Text("Important", textStyle = TextStyle.Bold + TextStyle.Italic)
```

### Colors

The `Color` value class stores RGB as a packed 32-bit integer:

```kotlin
// Named constants
Color.Red
Color.Green
Color.Blue
Color.Black
Color.White
Color.Yellow
Color.Magenta
Color.Cyan

// Custom RGB (integer 0-255)
Color(128, 0, 255)

// Custom RGB (float 0.0-1.0)
Color(0.5f, 0.0f, 1.0f)
```

Colors are automatically downconverted based on detected terminal capabilities: true color terminals get full RGB, 256-color terminals get the nearest palette entry, and 16-color terminals get the nearest ANSI code based on brightness analysis.

### UnderlineStyle

Mosaic supports rich underline styles (terminals permitting):

| Style      | Description          |
| ---------- | -------------------- |
| `None`     | No underline         |
| `Straight` | Single solid line    |
| `Double`   | Two parallel lines   |
| `Curly`    | Wavy/undulating line |
| `Dotted`   | Dot pattern          |
| `Dashed`   | Dash pattern         |

Underline color can be set independently from text color.

### Styled Text Example

```kotlin
@Composable
fun StyledOutput() {
    Column {
        Text("Error: file not found",
            color = Color.Red,
            textStyle = TextStyle.Bold)

        Text("Warning: deprecated API",
            color = Color.Yellow,
            textStyle = TextStyle.Italic)

        Text(
            buildAnnotatedString {
                append("Status: ")
                withStyle(SpanStyle(color = Color.Green, textStyle = TextStyle.Bold)) {
                    append("ONLINE")
                }
            },
        )

        Text("secret",
            color = Color.Black,
            background = Color.Black,
            textStyle = TextStyle.Invert)
    }
}
```

### Background Modifier

The `background` modifier draws a colored rectangle behind the content:

```kotlin
Text(
    "PASS",
    modifier = Modifier.background(Color.Green).padding(horizontal = 1),
    color = Color.Black,
)
```

The implementation uses a `DrawModifier` that calls `drawRect(background = color)` before `drawContent()`, layering the background beneath the text.

---

## Event Handling

Mosaic is primarily an output-focused framework, but it provides keyboard input handling through a modifier-based event system integrated with Kotlin coroutines.

### Key Event Modifiers

The `onKeyEvent` and `onPreviewKeyEvent` modifiers attach keyboard handlers to any composable:

```kotlin
@Composable
fun InteractiveApp() {
    var message by remember { mutableStateOf("Press a key...") }

    Column(
        modifier = Modifier.onKeyEvent { event ->
            when (event) {
                KeyEvent("q") -> { /* handle quit */ true }
                KeyEvent("ArrowUp") -> { message = "Up!"; true }
                KeyEvent("ArrowDown") -> { message = "Down!"; true }
                else -> false  // Not consumed
            }
        },
    ) {
        Text(message)
    }
}
```

The `KeyEvent` data class captures the pressed key along with modifier flags:

```kotlin
data class KeyEvent(
    val key: String,
    val alt: Boolean = false,
    val ctrl: Boolean = false,
    val shift: Boolean = false,
)
```

### Two-Phase Event Propagation

Key events follow a two-phase dispatch model similar to Android's touch events:

1. **Preview phase (downward)**: `onPreviewKeyEvent` handlers fire from ancestor to descendant. Returning `true` intercepts the event before it reaches children.
2. **Bubble phase (upward)**: `onKeyEvent` handlers fire from the focused component back up to ancestors. Returning `true` stops propagation.

### Robot Example: Full Interactive Application

```kotlin
fun main() = runMosaicMain {
    var x by remember { mutableIntStateOf(0) }
    var y by remember { mutableIntStateOf(0) }
    var exit by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.onKeyEvent {
            when (it) {
                KeyEvent("ArrowUp") -> y = (y - 1).coerceAtLeast(0)
                KeyEvent("ArrowDown") -> y = (y + 1).coerceAtMost(9)
                KeyEvent("ArrowLeft") -> x = (x - 1).coerceAtLeast(0)
                KeyEvent("ArrowRight") -> x = (x + 1).coerceAtMost(17)
                KeyEvent("q") -> exit = true
                else -> return@onKeyEvent false
            }
            true
        },
    ) {
        Text("Use arrow keys to move. Press 'q' to exit.")
        Text("Position: $x, $y")
        Spacer(Modifier.height(1))
        Box(
            modifier = Modifier
                .drawBehind { drawRect('*', drawStyle = DrawStyle.Stroke(1)) }
                .padding(1)
                .size(20, 10),
        ) {
            Text("^_^", modifier = Modifier.offset { IntOffset(x, y) })
        }
    }

    if (!exit) {
        LaunchedEffect(Unit) { awaitCancellation() }
    }
}
```

### Terminal State

Mosaic exposes terminal state through Compose's `CompositionLocal` mechanism:

```kotlin
val state = LocalTerminalState.current
// state.focused  -- whether the terminal has focus
// state.theme    -- light/dark theme
// state.size     -- terminal dimensions (width, height)
```

This state is reactive: composables that read `LocalTerminalState` automatically recompose when the terminal is resized or focus changes.

---

## State Management

Mosaic inherits Compose's full snapshot state system, which is one of the most sophisticated reactive state implementations in any UI framework.

### `mutableStateOf` -- Observable State

```kotlin
var name by remember { mutableStateOf("World") }
// Reading `name` during composition registers a dependency.
// Writing `name` triggers recomposition of readers.
```

Specialized variants avoid boxing overhead:

```kotlin
var count by remember { mutableIntStateOf(0) }
var ratio by remember { mutableFloatStateOf(1.0f) }
```

### `remember` -- State Survival

`remember` stores a value in the slot table so it persists across recompositions. Without `remember`, values would be re-initialized every time the function re-executes:

```kotlin
@Composable
fun ExpensiveComputation(input: List<Int>) {
    // Recomputed only when `input` changes
    val sorted = remember(input) { input.sorted() }
    Text("First: ${sorted.first()}, Last: ${sorted.last()}")
}
```

### `derivedStateOf` -- Computed State

Creates state that is automatically recomputed when its dependencies change, but only triggers recomposition when the derived value itself changes:

```kotlin
@Composable
fun FilteredList(items: List<String>, query: String) {
    val filtered by remember(items, query) {
        derivedStateOf { items.filter { it.contains(query) } }
    }
    Column {
        filtered.forEach { Text(it) }
    }
}
```

### `snapshotFlow` -- State to Flow Bridge

Converts snapshot state reads into a Kotlin `Flow`, bridging the reactive state system with coroutine-based streaming:

```kotlin
LaunchedEffect(Unit) {
    snapshotFlow { count }
        .filter { it > 0 && it % 10 == 0 }
        .collect { milestone ->
            // Log every 10th count
        }
}
```

### Observable Collections

Compose provides snapshot-aware collection types:

```kotlin
val items = remember { mutableStateListOf<String>() }
val settings = remember { mutableStateMapOf<String, Int>() }
// Mutations to these collections trigger recomposition of readers.
```

### State Hoisting Pattern

Mosaic follows Compose's state hoisting convention: state flows down, events flow up.

```kotlin
@Composable
fun App() {
    var selected by remember { mutableIntStateOf(0) }
    val items = listOf("Alpha", "Beta", "Gamma")

    Menu(
        items = items,
        selectedIndex = selected,
        onSelect = { selected = it },
    )
}

@Composable
fun Menu(items: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit) {
    Column(
        modifier = Modifier.onKeyEvent { event ->
            when (event) {
                KeyEvent("ArrowUp") -> { onSelect((selectedIndex - 1).coerceAtLeast(0)); true }
                KeyEvent("ArrowDown") -> { onSelect((selectedIndex + 1).coerceAtMost(items.lastIndex)); true }
                else -> false
            }
        },
    ) {
        items.forEachIndexed { index, item ->
            val prefix = if (index == selectedIndex) "> " else "  "
            val color = if (index == selectedIndex) Color.Cyan else Color.Unspecified
            Text("$prefix$item", color = color)
        }
    }
}
```

### Reactive State Driving UI Updates

A complete example showing how state mutations automatically drive recomposition:

```kotlin
fun main() {
    runMosaicBlocking(onNonInteractive = Ignore) {
        val tests = remember { mutableStateListOf<Test>() }
        var elapsed by remember { mutableIntStateOf(0) }
        var done by remember { mutableStateOf(false) }

        LaunchedEffect(Unit) {
            launch {
                // Simulate test execution
                listOf("auth", "api", "db").forEach { name ->
                    tests += Test(name, Running)
                    delay(1500)
                    tests[tests.lastIndex] = tests.last().copy(state = Pass)
                }
                done = true
            }
        }

        LaunchedEffect(done) {
            while (!done) { delay(1000); elapsed++ }
        }

        // This entire block recomposes only where state is read:
        Column {
            tests.forEach { test -> TestRow(test) }  // Recomposes when `tests` mutates
            Text("Time: ${elapsed}s")                 // Recomposes when `elapsed` changes
            if (!done) Text("Running...")             // Recomposes when `done` changes
        }
    }
}
```

---

## Extensibility and Ecosystem

Mosaic is a relatively standalone library. It does not maintain a large ecosystem of third-party widgets or plugins. Its extensibility comes from the inherent composability of the Compose model and integration with the broader Kotlin ecosystem.

### Kotlin Coroutines Integration

Mosaic is deeply integrated with Kotlin coroutines. `runMosaic` is a suspend function. `LaunchedEffect` launches coroutines. `snapshotFlow` bridges reactive state with `Flow`. Any coroutine-based library (networking, file I/O, timers) integrates naturally.

### Kotlin Flows

Since state can be observed via `snapshotFlow`, and coroutines can collect external flows within `LaunchedEffect`, Mosaic composes naturally with reactive streams:

```kotlin
@Composable
fun LogViewer(logFlow: Flow<String>) {
    val lines = remember { mutableStateListOf<String>() }
    LaunchedEffect(logFlow) {
        logFlow.collect { lines += it }
    }
    Column {
        lines.takeLast(20).forEach { Text(it) }
    }
}
```

### Testing via `runMosaicTest`

The `mosaic-testing` module provides a test harness:

```kotlin
suspend fun runMosaicTest(
    capabilities: Terminal.Capabilities = TestTerminal.Capabilities(),
    block: suspend TestMosaic<String>.() -> Unit,
)
```

The `TestMosaic<String>` interface provides:

- `setContentAndSnapshot()` -- set content and immediately capture output.
- `awaitSnapshot(duration)` -- wait for state changes and capture output.
- `sendKeyEvent()` -- inject keyboard events.

Snapshots are plain text (ANSI stripped), enabling string-based assertions for visual regression testing.

### Sample Applications

The repository includes six samples demonstrating different patterns:

| Sample  | Demonstrates                                                        |
| ------- | ------------------------------------------------------------------- |
| counter | Basic state and timed updates                                       |
| demo    | Feature showcase                                                    |
| jest    | Test runner UI with `StaticEffect`, progress bar, `AnnotatedString` |
| robot   | Keyboard input, interactive movement                                |
| rrtop   | System monitoring dashboard                                         |
| snake   | Full game with ViewModel pattern                                    |

---

## Strengths

- **Compiler-powered recomposition**: The Compose compiler plugin inserts precise change-detection checks at compile time. Unlike virtual DOM diffing, there is no runtime tree comparison -- only changed functions re-execute.
- **Minimal re-execution on state change**: The snapshot system tracks exactly which composables read which state, enabling surgical recomposition with zero wasted work.
- **Familiar to Android/Compose developers**: Anyone who has written Jetpack Compose or Compose Multiplatform code can immediately write Mosaic code. The API surface is intentionally parallel.
- **Reactive state is automatic**: No manual subscriptions, no `observe()` calls, no explicit dependency declarations. Read a state value during composition and you are subscribed.
- **Deep coroutine integration**: `LaunchedEffect`, `snapshotFlow`, structured concurrency, and cancellation all work seamlessly for managing async operations in terminal UIs.
- **Kotlin's expressive syntax**: Property delegates (`by`), trailing lambdas, extension functions, and inline classes make the API ergonomic and type-safe.
- **Real Compose runtime guarantees**: Positional memoization, consistent snapshot reads, atomic state commits, and idempotent recomposition are all inherited from the battle-tested Compose runtime.
- **Multiplatform**: Runs on JVM, native Linux/macOS/Windows, and experimentally on JS.
- **Rich layout model**: The constraint-based layout system with `Row`, `Column`, `Box`, custom `Layout`, and modifiers is far more sophisticated than most TUI frameworks offer.

---

## Weaknesses and Limitations

- **Requires Kotlin and the Compose compiler plugin**: The entire approach depends on a Kotlin compiler plugin that rewrites function signatures. This is not portable to other languages and adds build complexity.
- **JVM startup overhead**: On the JVM target, there is noticeable startup latency from class loading and JIT compilation. Native targets mitigate this but have their own limitations.
- **Limited built-in widget set**: Mosaic provides `Text`, `Row`, `Column`, `Box`, `Spacer`, and `Filler`. There are no built-in tables, scrollable lists, input fields, borders, or dialog components.
- **Primarily output-focused**: While key event handling exists, there is no built-in focus management, tab navigation, mouse support, or input field abstraction. Interactive applications must build these from primitives.
- **Small community**: Compared to alternatives like Textual (Python), Bubbletea (Go), or Ratatui (Rust), Mosaic has a much smaller user base and fewer third-party components.
- **Less mature than alternatives**: Despite years of development, Mosaic is still labeled experimental. APIs change between releases, and some features are incomplete.
- **Debugging difficulty**: Compose's slot table and recomposition behavior can be opaque. Understanding why something recomposes (or fails to) requires deep knowledge of Compose internals.
- **No scrolling or viewport abstraction**: Long content simply overflows. There is no built-in scrollable container.

---

## Lessons for D / Sparkles

Mosaic demonstrates that a compiler-plugin-powered reactive model produces remarkably clean terminal UI code. While D lacks Kotlin's compiler plugin infrastructure, many of the patterns can be approximated using D's compile-time capabilities.

### Compiler Plugin Recomposition --> CTFE + Templates

Compose's compiler plugin transforms `@Composable` functions to thread composition context and insert skip-checks. D cannot rewrite function bodies at compile time, but it can generate boilerplate:

- **`mixin` templates** could generate recomposition tracking for struct fields. A `mixin Reactive!(MyState)` could introspect the fields of `MyState` and generate change-detection logic.
- **CTFE** can compute layout properties, style constants, and widget trees at compile time, eliminating the need for runtime tree construction in static cases.
- **Template metaprogramming** can validate composable function signatures at compile time, catching errors like incorrect return types or invalid modifier chains.

### Snapshot State --> Wrapper Structs with `opDispatch`

Compose's `mutableStateOf` creates observable state that triggers recomposition on write. D can approximate this:

```d
struct Reactive(T) {
    private T _value;
    private bool _dirty;

    T opCall() const { return _value; }  // read
    void opAssign(T v) {                 // write
        if (_value != v) {
            _value = v;
            _dirty = true;
        }
    }
    bool isDirty() const { return _dirty; }
    void clearDirty() { _dirty = false; }
}
```

Using `opDispatch` or `alias this`, a `Reactive!int` could be used almost transparently as an `int` while tracking mutations. Combined with Design by Introspection, a render loop could check `isDirty` on all reactive fields to decide what to re-render.

### `@Composable` Functions --> Template Functions Producing Element Trees

In Compose, `@Composable` functions build a tree implicitly through the `Composer`. In D, composable functions could return explicit element trees:

```d
auto statusBadge(string label, bool active) {
    return row(
        text(active ? "ON " : "OFF")
            .bg(active ? Color.green : Color.red)
            .pad(0, 1),
        text(" " ~ label),
    );
}
```

Compile-time validation via template constraints can ensure these functions return valid `Element` types, catching composition errors at build time.

### Modifier Chains --> UFCS

Compose's `Modifier.width(10).padding(2).background(Color.Red)` maps directly to D's UFCS:

```d
auto element = text("hello")
    .bold
    .pad(1)
    .fillMaxWidth
    .bg(Color.blue);
```

Each UFCS call returns a modified copy of the element or wraps it in a modifier node. D's `@property` attribute enables modifier-like accessors without parentheses for flags like `.bold` and `.italic`.

### Layout Protocol --> Template Constraints

Mosaic's `MeasurePolicy` interface (with `measure` receiving `Measurable` children and `Constraints`) can be modeled in D using template constraints and Design by Introspection:

```d
enum isLayout(T) = __traits(hasMember, T, "measure")
    && __traits(hasMember, T, "place");

auto customLayout(L)(L layout, Element[] children)
if (isLayout!L)
{
    // Use layout.measure(children, constraints)
    // Then layout.place(children, positions)
}
```

This provides compile-time validation that custom layouts implement the required protocol, similar to how Compose validates `MeasurePolicy` implementations at the type level.

### Reactive State --> Introspection-Based Dirty Tracking

Compose's snapshot system tracks reads during composition to build a dependency graph. D can approximate this with a render context that records field accesses:

```d
struct RenderContext {
    bool[string] readFields;

    auto track(T)(ref Reactive!T field, string name) {
        readFields[name] = true;
        return field();
    }
}
```

When state changes, the framework checks which render functions read the changed field and marks only those for re-execution. This is coarser than Compose's per-expression tracking but achieves the same goal of avoiding unnecessary re-renders.

### Coroutine Effects --> Fibers or `std.concurrency`

Compose's `LaunchedEffect` launches a coroutine scoped to the composition lifetime. D offers several analogous mechanisms:

- **Fibers** (`core.thread.fiber`): Cooperative multitasking that can yield during I/O waits, similar to how coroutines suspend.
- **`std.concurrency`**: Message-passing concurrency for spawning background tasks that communicate results back to the render thread.
- **Event loop integration**: A render loop that polls fibers, processes messages, and redraws on state changes mirrors Mosaic's frame-based rendering.

### TextSurface / TextPixel --> Character Grid with Differential Rendering

Mosaic's `TextSurface` is a grid of `TextPixel` objects, each storing a code point and style attributes. The renderer emits ANSI codes only when attributes change between adjacent pixels. This differential encoding pattern is directly applicable to a D implementation:

```d
struct TextPixel {
    dchar codePoint = ' ';
    Color fg = Color.unspecified;
    Color bg = Color.unspecified;
    Style style;
}
```

A D renderer can maintain a front buffer and back buffer, comparing them to emit only the changes -- a classic double-buffering approach that Mosaic's `AnsiRendering` essentially implements with its reused `StringBuilder`.

---

## References

- **GitHub Repository**: <https://github.com/JakeWharton/mosaic>
- **Compose Runtime (upstream)**: <https://developer.android.com/jetpack/compose/mental-model>
- **Compose Compiler Plugin**: <https://developer.android.com/jetpack/compose/compiler>
- **Compose Snapshot System**: <https://dev.to/zachklipp/introduction-to-the-compose-snapshot-system-19cn>
- **Jake Wharton's "Compose Runtime" Talk**: <https://jakewharton.com/a-jetpack-compose-by-any-other-name/>
- **Ink (JavaScript inspiration)**: <https://github.com/vadimdemedes/ink>
- **Mosaic Changelog**: <https://github.com/JakeWharton/mosaic/blob/trunk/CHANGELOG.md>
- **Kotlin Compose Multiplatform**: <https://www.jetbrains.com/compose-multiplatform/>
- **Mosaic Maven Central**: `com.jakewharton.mosaic:mosaic-runtime:0.18.0`
