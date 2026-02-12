# Ink (JavaScript)

React-based declarative component framework for building and testing command-line interfaces using Flexbox layout.

| Field          | Value                                        |
| -------------- | -------------------------------------------- |
| Language       | JavaScript / TypeScript (Node.js)            |
| License        | MIT                                          |
| Repository     | <https://github.com/vadimdemedes/ink>        |
| Documentation  | <https://github.com/vadimdemedes/ink#readme> |
| Latest Version | ~6.7.0                                       |
| GitHub Stars   | ~35k                                         |

## Overview

Ink is a React renderer for command-line applications. It provides the same component-based UI building experience that React offers in the browser, but targeting terminal output instead of the DOM. The core idea is captured by its tagline: "React for CLIs. Build and test your CLI output using components."

### What It Solves

Traditional CLI tools are built with imperative string concatenation and manual cursor management. Ink replaces this with a declarative component model where developers describe _what_ the UI should look like, and the framework handles rendering, diffing, and incremental updates to the terminal. This makes it straightforward to build rich, interactive terminal UIs with progress bars, tables, spinners, selection lists, and multi-panel layouts.

### Design Philosophy

Ink is built on a declarative, component-driven philosophy inherited directly from React. Every piece of terminal output is a component. Layout is handled by Flexbox (via Yoga), not manual column counting. State changes trigger re-renders, and the framework diffs the output to minimize terminal writes. All text must be explicitly wrapped in `<Text>` components, enforcing a clean separation between layout containers and content.

### History

Ink was created by **Vadim Demedes** and first released in 2017. It was inspired by React Native's approach of using React's component model and reconciler outside the browser. The project evolved through several major versions: Ink 2 introduced hooks support, Ink 3 brought major API improvements, Ink 4 upgraded to modern React patterns, and Ink 5/6 added features like concurrent rendering, the Kitty keyboard protocol, ARIA accessibility attributes, and screen reader support.

Ink is used by a wide range of popular tools, including **Jest** (Facebook's testing framework), **Gatsby CLI**, **Terraform CDK CLI**, **Prisma**, **Cloudflare Wrangler**, **Shopify CLI**, **GitHub Copilot CLI**, and many others.

## Architecture

### Rendering Model: Retained-Mode with React Reconciler

Ink uses a **retained-mode** rendering architecture built on top of `react-reconciler` (the same package that powers React DOM and React Native). This means Ink maintains an internal representation of the component tree and manages its lifecycle through React's standard reconciliation process.

The rendering pipeline works as follows:

1. **Component tree** -- The developer writes JSX components using `<Box>`, `<Text>`, and custom components. React manages the component tree, handling state, effects, and context.

2. **Reconciliation** -- When state changes (via `useState`, `useReducer`, etc.), React's reconciler diffs the virtual tree against the previous version, determining the minimal set of changes.

3. **Layout computation** -- Changed nodes are passed to Yoga (Facebook's Flexbox layout engine) which computes the absolute position and dimensions of every element in terminal-cell coordinates.

4. **Output generation** -- The laid-out tree is rendered to a string buffer with ANSI escape codes for styling (colors, bold, underline, etc.).

5. **Terminal flush** -- The rendered string is written to stdout, replacing the previous output. Ink uses a patching mechanism: it moves the cursor up to the start of its output region and overwrites only what changed, reducing flicker.

This architecture means Ink components behave exactly like React components. Developers can use `useState`, `useEffect`, `useContext`, `useReducer`, `useMemo`, `useCallback`, `useRef`, Suspense, and even React DevTools.

```
JSX Components
    |
    v
React Reconciler (react-reconciler ^0.33.0)
    |
    v
Ink Host Config (custom renderer)
    |
    v
Yoga Layout Engine (yoga-layout ~3.2.1)
    |
    v
ANSI String Buffer
    |
    v
stdout (with incremental patching)
```

The default maximum frame rate is **30 FPS**, configurable via the `maxFps` option in the `render()` call. Ink also supports **concurrent rendering** mode (React 19 features like Suspense, deferred values) via the `concurrent: true` option.

## Terminal Backend

### Layout Engine: Yoga

Ink uses **Yoga** (`yoga-layout ~3.2.1`), Facebook's cross-platform Flexbox layout engine. Yoga computes the position and size of every element in the component tree according to the Flexbox specification. In the terminal context, one "pixel" equals one character cell -- widths are measured in columns and heights in rows.

Every `<Box>` component is a Yoga node with `display: flex` by default. This means all layout is Flexbox-based, with no alternative layout modes (block, grid, absolute positioning outside of Flexbox).

### Terminal Output

Ink writes to stdout using ANSI escape codes for:

- **Cursor movement** -- moving up to overwrite previous output
- **Text styling** -- SGR (Select Graphic Rendition) codes for colors, bold, italic, underline, strikethrough, dim, and inverse
- **Color support** -- Named colors, hex (`#ff0000`), RGB (`rgb(255, 0, 0)`), and ANSI-256 palette, powered by chalk's color detection and downsampling

### Patching Mechanism

Rather than clearing and redrawing the entire screen on each render, Ink uses an incremental patching approach:

1. After Yoga computes layout, Ink renders the tree to a string buffer.
2. The framework tracks how many lines its output occupies.
3. On re-render, it moves the cursor up to the beginning of its output region.
4. It overwrites the previous output with the new content, clearing any trailing characters.

This approach avoids full-screen flicker and works well for CLI tools that show a bounded region of output (progress bars, status displays, interactive prompts).

### CI and Non-Interactive Mode

Ink detects non-interactive environments (CI, piped output) and can adjust behavior accordingly. The `isRawModeSupported` property from `useStdin()` indicates whether the terminal supports raw mode input. When raw mode is not available, interactive features like keyboard input are gracefully disabled.

### Console Patching

By default (`patchConsole: true`), Ink intercepts `console.log`, `console.error`, and similar calls. When a console method is called, Ink clears its output, writes the console message, and re-renders its component tree below it. This prevents console output from corrupting the Ink UI.

## Layout System

Ink implements a comprehensive Flexbox layout system via Yoga. Every `<Box>` component is a flex container by default (`display: flex`). The layout system supports the following properties:

### Flex Container Properties

| Property         | Values                                                                                          | Default        |
| ---------------- | ----------------------------------------------------------------------------------------------- | -------------- |
| `flexDirection`  | `'row'`, `'row-reverse'`, `'column'`, `'column-reverse'`                                        | `'row'`        |
| `justifyContent` | `'flex-start'`, `'center'`, `'flex-end'`, `'space-between'`, `'space-around'`, `'space-evenly'` | `'flex-start'` |
| `alignItems`     | `'flex-start'`, `'center'`, `'flex-end'`                                                        | `'flex-start'` |
| `flexWrap`       | `'nowrap'`, `'wrap'`, `'wrap-reverse'`                                                          | `'nowrap'`     |

### Flex Item Properties

| Property     | Type                                         | Default  |
| ------------ | -------------------------------------------- | -------- |
| `flexGrow`   | `number`                                     | `0`      |
| `flexShrink` | `number`                                     | `1`      |
| `flexBasis`  | `number\|string`                             | --       |
| `alignSelf`  | `'auto'\|'flex-start'\|'center'\|'flex-end'` | `'auto'` |

### Dimensions

| Property    | Type             | Description              |
| ----------- | ---------------- | ------------------------ |
| `width`     | `number\|string` | Columns or percentage    |
| `height`    | `number\|string` | Rows or percentage       |
| `minWidth`  | `number`         | Minimum width in columns |
| `minHeight` | `number`         | Minimum height in rows   |

### Spacing

Padding and margin are specified in character cells:

- `padding`, `paddingX`, `paddingY`, `paddingTop`, `paddingBottom`, `paddingLeft`, `paddingRight`
- `margin`, `marginX`, `marginY`, `marginTop`, `marginBottom`, `marginLeft`, `marginRight`
- `gap`, `columnGap`, `rowGap`

### Overflow and Display

| Property    | Values                  | Default     |
| ----------- | ----------------------- | ----------- |
| `display`   | `'flex'`, `'none'`      | `'flex'`    |
| `overflowX` | `'visible'`, `'hidden'` | `'visible'` |
| `overflowY` | `'visible'`, `'hidden'` | `'visible'` |
| `overflow`  | shorthand for X and Y   | `'visible'` |

### Multi-Panel Layout Example

```jsx
import React from "react";
import { render, Box, Text } from "ink";

function Dashboard() {
  return (
    <Box flexDirection="column" width={80} height={24}>
      {/* Header bar */}
      <Box
        borderStyle="single"
        borderColor="cyan"
        justifyContent="center"
        paddingX={1}
      >
        <Text bold color="cyan">
          Dashboard v1.0
        </Text>
      </Box>

      {/* Main content area: sidebar + content */}
      <Box flexGrow={1} flexDirection="row">
        {/* Sidebar */}
        <Box
          flexDirection="column"
          width={20}
          borderStyle="single"
          borderColor="gray"
          paddingX={1}
        >
          <Text bold underline>
            Navigation
          </Text>
          <Text color="green"> > Overview</Text>
          <Text> Processes</Text>
          <Text> Network</Text>
          <Text> Settings</Text>
        </Box>

        {/* Main content */}
        <Box
          flexDirection="column"
          flexGrow={1}
          borderStyle="single"
          borderColor="gray"
          paddingX={1}
        >
          <Text bold underline>
            System Overview
          </Text>
          <Box marginTop={1} gap={2}>
            <Box flexDirection="column">
              <Text dimColor>CPU Usage</Text>
              <Text color="green" bold>
                23%
              </Text>
            </Box>
            <Box flexDirection="column">
              <Text dimColor>Memory</Text>
              <Text color="yellow" bold>
                4.2 GB / 16 GB
              </Text>
            </Box>
            <Box flexDirection="column">
              <Text dimColor>Disk</Text>
              <Text color="red" bold>
                87% full
              </Text>
            </Box>
          </Box>
          <Box marginTop={1} flexDirection="column">
            <Text dimColor>Uptime</Text>
            <Text>14 days, 3 hours, 22 minutes</Text>
          </Box>
        </Box>
      </Box>

      {/* Status bar */}
      <Box
        justifyContent="space-between"
        paddingX={1}
        borderStyle="single"
        borderColor="gray"
      >
        <Text dimColor>Connected to localhost</Text>
        <Text dimColor>Last refresh: 2s ago</Text>
      </Box>
    </Box>
  );
}

render(<Dashboard />);
```

This produces a terminal layout with a centered header, a two-column body (sidebar with navigation, main area with metrics), and a footer status bar -- all computed by Yoga's Flexbox engine.

## Widget / Component System

### Built-in Components

**`<Box>`** -- The primary layout container. Acts as a Flexbox div. All layout props described above apply to Box. It also supports borders and background colors, making it suitable for panels, cards, and frames.

**`<Text>`** -- The only component that can contain text content. Supports styling props (see Styling section below). Text wrapping behavior is controlled via the `wrap` prop. Nested `<Text>` components inherit styling from their parent.

**`<Newline>`** -- Inserts line breaks. Accepts a `count` prop (default `1`) to insert multiple blank lines.

**`<Spacer>`** -- A flexible space filler that expands along the main axis of the parent flex container. Equivalent to a `<Box>` with `flexGrow={1}`. Commonly used to push elements to opposite ends of a row.

**`<Static>`** -- Renders items that should appear once and never re-render. Useful for log-style output where previous lines should remain unchanged while new content appends below. Accepts an `items` array and a `children` render function:

```jsx
<Static items={logs}>
  {(log, index) => (
    <Text key={index} color="gray">
      {log.timestamp} {log.message}
    </Text>
  )}
</Static>
```

**`<Transform>`** -- Applies a transformation function to its children's rendered output, line by line. Useful for adding prefixes, indentation, or post-processing:

```jsx
<Transform transform={(output) => `>> ${output}`}>
  <Text>This line will be prefixed</Text>
</Transform>
```

### Hooks

**`useInput(handler, options?)`** -- Subscribes to keyboard input. The handler receives `(input: string, key: Key)` where `key` contains boolean flags for special keys. Can be deactivated with `isActive: false`.

**`useApp()`** -- Returns `{ exit }` to programmatically unmount the application. Optionally accepts an `Error` to exit with a failure.

**`useFocus(options?)`** -- Returns `{ isFocused }`. Components using this hook become focusable via Tab/Shift+Tab navigation. Options include `autoFocus`, `isActive`, and `id`.

**`useFocusManager()`** -- Returns methods to control focus programmatically: `enableFocus()`, `disableFocus()`, `focusNext()`, `focusPrevious()`, `focus(id)`.

**`useStdin()`** -- Returns `{ stdin, isRawModeSupported, setRawMode }` for low-level stdin access.

**`useStdout()`** -- Returns `{ stdout, write }` for writing to stdout without disrupting Ink's output.

**`useStderr()`** -- Returns `{ stderr, write }` for writing to stderr without disrupting Ink's output.

**`useCursor()`** -- Returns `{ setCursorPosition }` to place or hide the terminal cursor.

**`useIsScreenReaderEnabled()`** -- Returns a boolean indicating whether a screen reader is active.

### Custom Components

Custom components are standard React function components. There is no special registration or base class required. Any function that returns JSX using Ink's built-in components is a valid Ink component:

```jsx
import React, { useState, useEffect } from "react";
import { Box, Text, useInput, useApp } from "ink";

function Timer() {
  const [seconds, setSeconds] = useState(0);
  const [running, setRunning] = useState(true);
  const { exit } = useApp();

  useEffect(() => {
    if (!running) return;

    const timer = setInterval(() => {
      setSeconds((prev) => prev + 1);
    }, 1000);

    return () => clearInterval(timer);
  }, [running]);

  useInput((input, key) => {
    if (input === " ") {
      setRunning((prev) => !prev);
    }
    if (input === "q") {
      exit();
    }
  });

  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  const display = `${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;

  return (
    <Box flexDirection="column" alignItems="center" padding={1}>
      <Text bold>Stopwatch</Text>
      <Box marginY={1}>
        <Text color={running ? "green" : "yellow"} bold>
          {display}
        </Text>
      </Box>
      <Text dimColor>
        {running ? "Press SPACE to pause" : "Press SPACE to resume"}
        {" | Press Q to quit"}
      </Text>
    </Box>
  );
}
```

This example demonstrates `useState` for local state, `useEffect` for a timer side-effect with cleanup, `useInput` for keyboard handling, and `useApp` for programmatic exit.

## Styling

Ink's styling is applied through props rather than CSS stylesheets or class names. There are two main surfaces for styling: `<Box>` for layout and border decoration, and `<Text>` for text appearance.

### Box Styling

`<Box>` supports border and background styling:

| Prop                | Type      | Description                                                                                                    |
| ------------------- | --------- | -------------------------------------------------------------------------------------------------------------- |
| `borderStyle`       | `string`  | `'single'`, `'double'`, `'round'`, `'bold'`, `'singleDouble'`, `'doubleSingle'`, `'classic'`, or custom object |
| `borderColor`       | `string`  | Color for all borders                                                                                          |
| `borderTopColor`    | `string`  | Color for top border                                                                                           |
| `borderRightColor`  | `string`  | Color for right border                                                                                         |
| `borderBottomColor` | `string`  | Color for bottom border                                                                                        |
| `borderLeftColor`   | `string`  | Color for left border                                                                                          |
| `borderDimColor`    | `boolean` | Dim all borders                                                                                                |
| `borderTop`         | `boolean` | Show/hide top border (default `true`)                                                                          |
| `borderRight`       | `boolean` | Show/hide right border                                                                                         |
| `borderBottom`      | `boolean` | Show/hide bottom border                                                                                        |
| `borderLeft`        | `boolean` | Show/hide left border                                                                                          |
| `backgroundColor`   | `string`  | Fill the entire box area                                                                                       |

Custom border styles can be provided as an object with `topLeft`, `top`, `topRight`, `right`, `bottomRight`, `bottom`, `bottomLeft`, `left` keys.

### Text Styling

`<Text>` supports the following style props:

| Prop              | Type      | Default  | Description                                                                       |
| ----------------- | --------- | -------- | --------------------------------------------------------------------------------- |
| `color`           | `string`  | --       | Text foreground color                                                             |
| `backgroundColor` | `string`  | --       | Text background color                                                             |
| `bold`            | `boolean` | `false`  | Bold weight                                                                       |
| `italic`          | `boolean` | `false`  | Italic style                                                                      |
| `underline`       | `boolean` | `false`  | Underline decoration                                                              |
| `strikethrough`   | `boolean` | `false`  | Strikethrough decoration                                                          |
| `dimColor`        | `boolean` | `false`  | Reduced brightness                                                                |
| `inverse`         | `boolean` | `false`  | Swap foreground and background                                                    |
| `wrap`            | `string`  | `'wrap'` | `'wrap'`, `'truncate'`, `'truncate-start'`, `'truncate-middle'`, `'truncate-end'` |

### Color Formats

Colors support multiple formats (powered by chalk's terminal color detection):

- **Named colors**: `'red'`, `'green'`, `'blue'`, `'cyan'`, `'magenta'`, `'yellow'`, `'white'`, `'gray'`, etc.
- **Hex**: `'#ff6347'`, `'#00ff00'`
- **RGB**: `'rgb(255, 99, 71)'`
- **ANSI-256**: Chalk automatically downsamples to the best available color depth for the terminal.

### Styling Code Example

```jsx
import React from "react";
import { render, Box, Text } from "ink";

function StyledCard({ title, status, description }) {
  const statusColor =
    status === "passing" ? "green" : status === "failing" ? "red" : "yellow";

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor="cyan"
      paddingX={2}
      paddingY={1}
      width={50}
    >
      <Box justifyContent="space-between">
        <Text bold color="white">
          {title}
        </Text>
        <Text color={statusColor} bold inverse>
          {" "}
          {status.toUpperCase()}{" "}
        </Text>
      </Box>

      <Box marginTop={1}>
        <Text dimColor italic>
          {description}
        </Text>
      </Box>

      <Box marginTop={1}>
        <Text>
          Priority:{" "}
          <Text color="#ff6347" bold>
            HIGH
          </Text>
          {" | "}
          Updated: <Text underline>2 hours ago</Text>
        </Text>
      </Box>
    </Box>
  );
}

render(
  <StyledCard
    title="Build Pipeline"
    status="passing"
    description="All 247 tests passing across 12 suites"
  />,
);
```

## Event Handling

### Keyboard Input

The primary mechanism for handling keyboard input is the `useInput` hook. It receives two arguments: the raw input string, and a `key` object with boolean flags for special keys.

```jsx
import React, { useState } from "react";
import { Box, Text, useInput, useApp } from "ink";

function SelectableList({ items }) {
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [confirmed, setConfirmed] = useState(null);
  const { exit } = useApp();

  useInput((input, key) => {
    if (key.upArrow) {
      setSelectedIndex((prev) => Math.max(0, prev - 1));
    }

    if (key.downArrow) {
      setSelectedIndex((prev) => Math.min(items.length - 1, prev + 1));
    }

    if (key.return) {
      setConfirmed(items[selectedIndex]);
    }

    if (input === "q" || key.escape) {
      exit();
    }
  });

  if (confirmed) {
    return <Text color="green">Selected: {confirmed}</Text>;
  }

  return (
    <Box flexDirection="column">
      <Text bold>Choose an option (arrows to move, enter to select):</Text>
      {items.map((item, i) => (
        <Text key={item} color={i === selectedIndex ? "cyan" : undefined}>
          {i === selectedIndex ? "> " : "  "}
          {item}
        </Text>
      ))}
      <Text dimColor>Press Q or Escape to quit</Text>
    </Box>
  );
}
```

The `key` object provides boolean flags for:

- Arrow keys: `leftArrow`, `rightArrow`, `upArrow`, `downArrow`
- Action keys: `return`, `escape`, `tab`, `backspace`, `delete`
- Modifiers: `ctrl`, `shift`, `meta`
- Navigation: `pageDown`, `pageUp`, `home`, `end`
- Kitty protocol extras: `super`, `hyper`, `capsLock`, `numLock`, and `eventType` (`'press'`, `'repeat'`, `'release'`)

The `useInput` hook accepts an `isActive` option to conditionally disable input handling, which is useful for modal UIs or focus-dependent input.

### Focus Management

Ink provides a focus system via `useFocus` and `useFocusManager`. Components declare themselves as focusable, and users navigate with Tab/Shift+Tab:

```jsx
function FocusableItem({ label }) {
  const { isFocused } = useFocus();

  return (
    <Box>
      <Text color={isFocused ? "green" : "gray"}>
        {isFocused ? "> " : "  "}
        {label}
      </Text>
    </Box>
  );
}
```

Programmatic focus control is available through `useFocusManager()`:

```jsx
const { focusNext, focusPrevious, focus } = useFocusManager();
focusNext(); // Move focus to next component
focusPrevious(); // Move focus to previous component
focus("submit-btn"); // Focus a specific component by ID
```

### Mouse Support

Ink does **not** support mouse events. All interaction is keyboard-based.

### stdin Handling

For low-level input needs beyond `useInput`, the `useStdin` hook provides direct access:

```jsx
const { stdin, setRawMode, isRawModeSupported } = useStdin();
```

Raw mode must be enabled for character-by-character input. When raw mode is not supported (e.g., in CI environments), `isRawModeSupported` returns `false`.

## State Management

Ink uses React's standard state management primitives. There is no Ink-specific state system.

### React Built-in State

- **`useState`** -- Component-local state, the most common pattern. State changes trigger re-renders, which flow through the reconciler and Yoga layout engine to produce updated terminal output.

- **`useReducer`** -- For complex state logic with multiple sub-values or when the next state depends on the previous state.

- **`useEffect`** -- For side effects: timers, subscriptions, API calls. Cleanup functions run on unmount, making it safe for interval-based animations or polling.

- **`useContext`** -- For sharing state across the component tree without prop drilling. Commonly used for theme configuration or application-wide settings.

- **`useRef`** -- For mutable values that persist across renders without triggering re-renders. Also used with `measureElement` to get element dimensions.

- **`useMemo` / `useCallback`** -- For memoization and preventing unnecessary re-renders in complex component trees.

### External State Libraries

Because Ink components are standard React components, external state management libraries work without modification:

- **zustand** -- Lightweight stores with hooks
- **jotai** -- Atomic state management
- **Redux** (via `react-redux`) -- Centralized state with reducers
- **React Query / TanStack Query** -- Server state and async data fetching

### Component-Local State as Default

The idiomatic Ink pattern favors component-local state. CLI tools typically have simpler state requirements than web applications, and most Ink applications can be built entirely with `useState` and `useEffect`. Context is used when multiple components need to share state (e.g., a global configuration or theme).

## Extensibility and Ecosystem

Ink has a rich ecosystem of community components and tools:

### Testing

**[ink-testing-library](https://github.com/vadimdemedes/ink-testing-library)** -- The official testing utility. It provides a `render()` function that mounts components in a virtual terminal and exposes:

- `lastFrame()` -- Returns the most recent rendered output as a string
- `frames` -- Array of all rendered frames for asserting on rendering sequences
- `rerender(tree)` -- Update the component with new props
- `unmount()` -- Unmount the component
- `stdin.write(input)` -- Simulate keyboard input

```jsx
import { render } from "ink-testing-library";
import Counter from "./Counter.js";

const { lastFrame, stdin } = render(<Counter />);
assert.equal(lastFrame(), "Count: 0");

stdin.write("i"); // simulate pressing 'i' to increment
assert.equal(lastFrame(), "Count: 1");
```

### Popular Community Components

| Package            | Description                           |
| ------------------ | ------------------------------------- |
| `ink-select-input` | Interactive select/list input         |
| `ink-text-input`   | Text input field with cursor          |
| `ink-spinner`      | Animated loading spinners             |
| `ink-table`        | Formatted data tables                 |
| `ink-gradient`     | Gradient-colored text                 |
| `ink-link`         | Clickable terminal hyperlinks (OSC 8) |
| `ink-big-text`     | Large ASCII art text (figlet-style)   |

### Frameworks Built on Ink

**[Pastel](https://github.com/vadimdemedes/pastel)** -- A Next.js-inspired framework for building CLI apps on top of Ink. Provides file-system-based routing for commands, automatic argument parsing, and a structured project layout.

### Scaffolding

**`create-ink-app`** -- Official CLI scaffolding tool. Generates a starter Ink project with TypeScript support:

```bash
npx create-ink-app my-cli-tool --typescript
```

### React DevTools

Ink supports React DevTools for debugging component trees. Enable with the `DEV=true` environment variable and connect via `react-devtools-core`.

## Strengths

- **Familiar React mental model** -- Any developer with React experience can immediately build CLI applications. No new paradigm to learn, just a different render target.
- **Huge JavaScript/npm ecosystem** -- Access to hundreds of thousands of npm packages for data fetching, parsing, file system operations, and more.
- **Easy to test with ink-testing-library** -- Components can be rendered to strings and asserted against, making CLI UI testing as straightforward as testing React web components.
- **Flexbox layout is powerful and intuitive** -- Yoga provides a well-understood, battle-tested layout model. Developers do not need to manually compute column positions or row offsets.
- **Good for CLI tool UIs** -- Progress indicators, interactive prompts, multi-step wizards, and status dashboards are all natural fits for Ink's component model.
- **Declarative and composable** -- UI is described as a function of state, making it easy to reason about what the terminal shows at any given moment.
- **Rich component ecosystem** -- Pre-built components for common CLI patterns (selection lists, text inputs, spinners, tables) reduce boilerplate.
- **Full React feature support** -- Hooks, context, Suspense, concurrent mode, and React DevTools all work.
- **Accessibility support** -- ARIA roles, states, and labels with screen reader detection.
- **Incremental rendering** -- Patching mechanism avoids full redraws, reducing terminal flicker.

## Weaknesses and Limitations

- **Node.js runtime overhead** -- Requires a full Node.js process with React, react-reconciler, and Yoga loaded. Startup time and memory footprint are significant compared to native CLI tools.
- **No mouse support** -- All interaction is keyboard-based. Applications requiring mouse clicks, hover effects, or scroll wheels cannot use Ink.
- **Limited to what React's reconciler can express** -- The terminal is fundamentally different from a browser DOM. Some patterns (absolute positioning, z-index layering, overlapping elements) are difficult or impossible.
- **Yoga dependency adds complexity** -- Yoga is a native/WASM binary that must be compiled or bundled. This can cause issues in some deployment environments and adds to the dependency footprint.
- **Performance ceiling for complex UIs** -- React's reconciliation, Yoga's layout computation, and ANSI string generation all add overhead. High-frequency updates (e.g., smooth animations at 60 FPS) push against this ceiling.
- **Not suitable for full-screen high-refresh-rate applications** -- Games, terminal multiplexers, or text editors with complex scrolling are better served by lower-level libraries (blessed, ncurses, notcurses).
- **All text must be wrapped in `<Text>` components** -- A common source of runtime errors for new users who place bare strings inside `<Box>`.
- **JavaScript/TypeScript only** -- Cannot be used from other languages without Node.js interop.
- **Bundled output size** -- Distributing an Ink CLI means shipping Node.js dependencies, which can result in large `node_modules` trees compared to single-binary CLIs.
- **30 FPS default cap** -- While configurable, the rendering pipeline is not designed for frame-rate-sensitive applications.

## Lessons for D / Sparkles

Ink demonstrates several patterns that can be adapted to D's strengths, often with better performance characteristics due to compile-time computation and zero-overhead abstractions.

### Component Model via Compile-Time Introspection

Ink's component model relies on React's runtime reconciler to manage component lifecycle. In D, **compile-time introspection** (`__traits`, `is` expressions, template constraints) could define component interfaces as static contracts rather than runtime abstractions. A component could be any struct satisfying a trait (e.g., having a `render` method returning a layout node), with validation happening entirely at compile time:

```d
// D analogue: components as introspected structs
enum isComponent(T) = is(typeof((T t) {
    auto node = t.render();  // must have render()
    static assert(isLayoutNode!(typeof(node)));
}));
```

This eliminates the virtual dispatch, garbage collection, and runtime type checking overhead that React's reconciler requires.

### Flexbox Layout via CTFE

Ink uses Yoga (a WASM/native runtime dependency) to compute Flexbox layout. For **static layouts** where dimensions are known at compile time, D's CTFE could pre-compute the entire layout at compile time, producing a flat array of positioned rectangles with zero runtime cost. For dynamic layouts, a `@nogc` Yoga-equivalent could compute layout into a `SmallBuffer` without heap allocation:

```d
// Static layout computed at compile time
enum layout = flexLayout(
    box(direction: row, width: 80, children: [
        box(width: 20),    // sidebar
        box(flexGrow: 1),  // content
    ]),
);
// layout is a compile-time constant array of positioned rects
```

### Hooks Pattern via UFCS and Scope

Ink's hooks (`useState`, `useEffect`, `useInput`) are runtime constructs that rely on React's fiber architecture and call-order tracking. In D, similar patterns could use **UFCS chains** for composable state transformations and **scope-based resource management** for effect cleanup:

```d
// UFCS chain for state transformation
auto newState = currentState
    .handleInput(key)
    .applyLayout(termSize)
    .renderToBuffer(buf);

// Scope-based cleanup (analogous to useEffect cleanup)
auto subscription = onInput(&handleKey);
scope(exit) subscription.cancel();
```

### Virtual DOM Diffing via `@nogc` Buffers

Ink's rendering pipeline diffs a virtual tree and flushes changes to the terminal. D's `SmallBuffer` (already in Sparkles) could implement efficient terminal diffing without GC allocation. A double-buffering approach -- writing the new frame to one buffer while comparing against the previous frame in another -- maps naturally to `@nogc` D:

```d
@nogc nothrow
void renderFrame(ref SmallBuffer!(char, 4096) front, ref SmallBuffer!(char, 4096) back) {
    // Render new frame into `back`
    renderTree(root, back);
    // Diff against `front`, emit only changed ANSI sequences
    emitDiff(front[], back[], stdout);
    // Swap buffers
    swap(front, back);
}
```

### Declarative DSL via Mixins or IES

Ink's JSX provides a declarative syntax for describing UI trees. D could achieve a similar developer experience through **mixin templates** or **interpolated expression sequences** (IES, already documented in Sparkles' guidelines). An IES-based DSL could describe layout trees that compile down to direct struct construction:

```d
// Hypothetical D DSL using IES or string mixins
auto ui = box(
    direction: column,
    border: Border.single,
    children: [
        text("Dashboard", style: bold | color(Color.cyan)),
        box(direction: row, children: [
            text("CPU: 23%"),
            spacer(),
            text("MEM: 4.2GB"),
        ]),
    ],
);
```

### Testing via Output Ranges

Ink's `ink-testing-library` renders components to strings for assertion. In D, since Sparkles already uses output ranges extensively (`prettyPrint` writes to any output range), **testing terminal UI is natural**: render to a `SmallBuffer` or `appender!string` and compare the output. No special testing library is needed -- the output range pattern makes UI components inherently testable:

```d
@safe pure nothrow @nogc
unittest {
    SmallBuffer!(char, 4096) buf;
    renderComponent(myWidget, buf);
    assert(buf[] == expectedOutput);
}
```

## References

- **Repository**: <https://github.com/vadimdemedes/ink>
- **README / API Documentation**: <https://github.com/vadimdemedes/ink#readme>
- **npm Package**: <https://www.npmjs.com/package/ink>
- **ink-testing-library**: <https://github.com/vadimdemedes/ink-testing-library>
- **create-ink-app scaffolding**: <https://github.com/vadimdemedes/create-ink-app>
- **Pastel framework**: <https://github.com/vadimdemedes/pastel>
- **Yoga Layout Engine**: <https://github.com/nicolo-ribaudo/yoga>
- **react-reconciler**: <https://www.npmjs.com/package/react-reconciler>
- **Vadim Demedes (author)**: <https://github.com/vadimdemedes>
- **"Building a React Renderer" (Sophie Alpert talk)**: <https://www.youtube.com/watch?v=CGpMlWVcHok> -- foundational talk on custom React renderers that influenced Ink's architecture
- **Awesome Ink (community components)**: <https://github.com/vadimdemedes/ink#useful-components> -- curated list of Ink ecosystem packages
