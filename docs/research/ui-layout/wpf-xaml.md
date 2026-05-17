# WPF / XAML (.NET)

Windows Presentation Foundation's two-pass _Measure / Arrange_ layout protocol,
expressed declaratively in XAML markup. The same protocol underpins Silverlight, UWP,
.NET MAUI, Uno Platform, and Avalonia -- making it the most-replicated layout model
of any GUI framework.

| Field            | Value                                                               |
| ---------------- | ------------------------------------------------------------------- |
| Language         | C# / VB.NET / F# (any CLR language); XAML for markup                |
| License          | MIT (open source since 2018)                                        |
| Repository       | <https://github.com/dotnet/wpf>                                     |
| Documentation    | <https://learn.microsoft.com/en-us/dotnet/desktop/wpf/>             |
| First Release    | WPF 3.0 (November 2006, with .NET Framework 3.0)                    |
| Version snapshot | Open-source WPF in the modern .NET line; active maintenance         |
| Layout Protocol  | Two-pass: MeasureOverride -> ArrangeOverride                        |
| Notable Lineage  | Silverlight (2007), WinRT/UWP (2015), MAUI (2022), Avalonia (2016+) |

---

## Overview

### What It Is

WPF is Microsoft's retained-mode desktop UI framework. It pairs a C#/CLR object model
of `DependencyObject` / `UIElement` / `FrameworkElement` with an XML-based declarative
markup language called XAML. Layout is performed by a two-pass recursive protocol
where every element first reports how much space it _wants_ (Measure), then is told
how much space it _gets_ (Arrange).

### What It Solves

When WPF was designed, Windows Forms was the dominant .NET UI framework. WinForms
used absolute pixel positioning -- a button at (10, 20) was at (10, 20), period. This
made resolution-independent UI, multi-monitor DPI handling, and resizable layouts
painful. WPF replaced absolute coordinates with a layout-system-managed protocol:
the developer describes the _structure_ of the UI (a grid with three rows, two
columns, stretched buttons in the cells), and the layout system computes the actual
pixel coordinates based on the window size, font metrics, content sizes, and DPI.

The Measure/Arrange protocol decouples _what content needs_ from _what container
allocates_. A `TextBlock` measures the width of its text and reports a desired size;
a `Grid` arranges columns according to its `*` / `Auto` / fixed-pixel rules; the
two negotiate until every element has a final rectangle. This is the same idea as
Flutter's constraint protocol (see [flutter.md](./flutter.md)) but with two passes
instead of one, and with per-element attached properties instead of widget wrappers.

### Design Philosophy

Three principles drive WPF's layout design:

1. **Declarative over imperative.** UI structure is described in XAML markup, with
   code-behind only for behaviour. The markup is the source of truth; a designer
   tool (Visual Studio, Blend, or third-party) can manipulate the markup directly.
2. **Composition through panels.** Layout containers (called _panels_, all deriving
   from the `Panel` base class) provide specific arrangement strategies: `Grid`,
   `StackPanel`, `DockPanel`, `WrapPanel`, `Canvas`, `UniformGrid`. A layout is built
   by nesting panels.
3. **Per-element layout properties via attached properties.** Where a child sits inside
   a `Grid` is encoded on the child itself via attached properties:
   `Grid.Row="2" Grid.Column="1"`. The parent doesn't have to know about its children
   ahead of time; the children declare where they want to be.

### History

- **November 2006 -- WPF 3.0.** Shipped with .NET Framework 3.0 as "Avalon". The
  Measure/Arrange protocol, XAML markup, `Grid` / `StackPanel` / `DockPanel`, data
  binding, and the DependencyObject system were all there at launch.
- **April 2007 -- Silverlight 1.0.** Plug-in version of WPF for the web; 2.0 added
  the full XAML toolkit.
- **2015 -- UWP.** Windows 10's app platform inherits the XAML layout system.
- **2016 -- Avalonia.** An open-source rewrite of WPF/XAML targeting Windows, macOS,
  Linux, iOS, Android, and WebAssembly via Skia. Shares the Measure/Arrange protocol
  and `Grid` star sizing with WPF.
- **December 2018 -- WPF open-sourced** on GitHub under MIT; ported to .NET Core.
- **2020 -- Uno Platform.** Another cross-platform WPF/UWP-compatible runtime.
- **May 2022 -- .NET MAUI.** Successor to Xamarin.Forms; same Measure/Arrange model.
- **2024 -- WPF in .NET 9.** Active maintenance for long-tail enterprise apps.

WPF's biggest legacy is its _layout protocol_, which has propagated unchanged into
every framework Microsoft has built or inspired since. Anyone who has learned `Grid`
star sizing in WPF can use it identically in UWP, MAUI, Avalonia, and Uno.

### Comparison to Other Layout Models

For terminal-UI comparators see [Ratatui](../tui-libraries/ratatui.md) (immediate-mode
constraint solving via Cassowary) and [Ink](../tui-libraries/ink.md) (Flexbox via
Yoga). For an alternative single-pass model, see [Flutter](./flutter.md). Contrasts:

| Property              | WPF / XAML            | Flutter         | Ratatui           | Ink             |
| --------------------- | --------------------- | --------------- | ----------------- | --------------- |
| Passes per frame      | 2 (Measure + Arrange) | 1               | 1                 | 1               |
| Markup language       | XAML (XML)            | Dart            | Rust              | JSX             |
| Per-child positioning | Attached properties   | Widget wrappers | `Constraint` enum | Flexbox cascade |
| Star (`*`) sizing     | Built into Grid       | `Expanded` flex | `Fill(n)`         | `flexGrow: n`   |
| Auto sizing           | `Auto` in Grid        | Intrinsics      | `Min`/`Max`       | `flexShrink`    |

WPF's distinctive contribution is _star sizing_ -- the idea that columns and rows can
declare proportional sizes like `*`, `2*`, `Auto`, `200`, with the layout system
distributing leftover space among star-sized tracks. This is the most-copied feature
in the lineage.

---

## Layout Model

### The Two-Pass Protocol

Every element in a WPF UI participates in a two-pass layout cycle, driven by the
parent panel. The interface lives on `UIElement` and `FrameworkElement`:

```csharp
// UIElement methods invoked by the layout system:
public void Measure(Size availableSize);
public void Arrange(Rect finalRect);

// Read-back after Measure:
public Size DesiredSize { get; }

// Read-back after Arrange:
public Size RenderSize { get; }
public double ActualWidth { get; }
public double ActualHeight { get; }
```

A subclass overrides two protected methods to customise layout behaviour:

```csharp
// FrameworkElement (and Panel) extension points:
protected virtual Size MeasureOverride(Size availableSize);
protected virtual Size ArrangeOverride(Size finalSize);
```

### Pass 1: Measure

The Measure pass asks every element, "given this much space, how much do you _want_?"

```
Parent calls: child.Measure(availableSize)
  child computes its DesiredSize:
    - subtracts Margin from availableSize -> constraintSize
    - calls MeasureOverride(constraintSize) -> rawDesiredSize
    - clamps rawDesiredSize against Width/MinWidth/MaxWidth
    - adds Margin back
    - stores result in child.DesiredSize
```

`MeasureOverride` is where a panel measures its own children and aggregates their
desired sizes:

```csharp
protected override Size MeasureOverride(Size availableSize)
{
    double maxWidth = 0;
    double totalHeight = 0;
    foreach (UIElement child in InternalChildren)
    {
        child.Measure(availableSize);  // Recurse.
        maxWidth = Math.Max(maxWidth, child.DesiredSize.Width);
        totalHeight += child.DesiredSize.Height;
    }
    return new Size(maxWidth, totalHeight);  // What I want.
}
```

The Measure pass result is `DesiredSize` -- a hint to the parent. The parent is free
to ignore it (a `Canvas` ignores child desired sizes entirely; a `StackPanel` respects
them on the stacking axis and stretches them on the perpendicular axis).

### Pass 2: Arrange

After every descendant has reported its desired size, the parent decides how to
actually distribute the available space:

```
Parent calls: child.Arrange(finalRect)
  child computes its render rectangle:
    - subtracts Margin from finalRect -> arrangeSize
    - calls ArrangeOverride(arrangeSize) -> renderedSize
    - applies HorizontalAlignment / VerticalAlignment
    - sets RenderSize = renderedSize
    - stores final offset in the visual tree
```

`ArrangeOverride` positions children within the panel's final rectangle:

```csharp
protected override Size ArrangeOverride(Size finalSize)
{
    double y = 0;
    foreach (UIElement child in InternalChildren)
    {
        double h = child.DesiredSize.Height;
        child.Arrange(new Rect(0, y, finalSize.Width, h));
        y += h;
    }
    return finalSize;
}
```

Notice that Arrange receives `finalSize` -- the actual rectangle allocated by the
grandparent -- not the desired size. The element may have asked for 200x150 in
Measure and been allocated only 180x140 in Arrange. The element's `ArrangeOverride`
is responsible for handling this gracefully (typically by clipping or alignment).

### Why Two Passes?

The two passes solve a problem the one-pass protocol cannot: collaborative sizing.
A `Grid` with three star-sized columns (`*`, `2*`, `*`) must know all children's
desired widths in `Auto`-sized columns _before_ it can distribute the leftover space
among the star columns. With a single pass, you would either need backtracking or
multiple recursive layout calls per child.

In Measure, each `Auto`-column child reports its desired width; the Grid sums those,
subtracts from the available width, and divides the remainder among the star
columns according to their proportions. In Arrange, each child gets its final cell
rectangle.

The cost is roughly 2x layout time compared to Flutter's single-pass model. The
benefit is that constructs like star sizing and DockPanel's `LastChildFill` are
trivial to express -- you just need both passes.

### When Layout Runs

The layout system is invoked when:

- The root window is sized (first time or resize).
- `InvalidateMeasure()` is called on an element (queues a Measure pass).
- `InvalidateArrange()` is called on an element (queues an Arrange pass).
- A dependency property marked `AffectsMeasure` or `AffectsArrange` changes.
- `UpdateLayout()` is called explicitly (synchronous full layout pass).
- A new child is added to a panel's `Children` collection.
- A `LayoutTransform` is applied (forces a layout update; unlike `RenderTransform`,
  which only affects painting).

Each dependency property declares whether it affects measure or arrange via
`FrameworkPropertyMetadata`:

```csharp
public static readonly DependencyProperty WidthProperty =
    DependencyProperty.Register(
        nameof(Width),
        typeof(double),
        typeof(FrameworkElement),
        new FrameworkPropertyMetadata(
            double.NaN,
            FrameworkPropertyMetadataOptions.AffectsMeasure));
```

When `Width` changes, the layout system marks the element for Measure and propagates
the invalidation up the visual tree until it hits a layout boundary.

### Per-Element Layout Properties

Every `FrameworkElement` carries a fixed set of layout-influencing properties:

| Property                                                 | Purpose                                           |
| -------------------------------------------------------- | ------------------------------------------------- |
| `Width` / `Height` (`double` or `NaN`)                   | Desired size; `NaN` means "sized to content".     |
| `MinWidth` / `MaxWidth`, `MinHeight` / `MaxHeight`       | Clamp ranges.                                     |
| `Margin` (`Thickness`)                                   | Outer space; reduces available size.              |
| `Padding` (`Thickness`)                                  | Inner space (only on `Control`-derived elements). |
| `HorizontalAlignment`: `Left`/`Center`/`Right`/`Stretch` | How element fills its cell horizontally.          |
| `VerticalAlignment`: `Top`/`Center`/`Bottom`/`Stretch`   | Same, vertically.                                 |
| `Visibility`: `Visible`/`Collapsed`/`Hidden`             | See below.                                        |
| `ClipToBounds` (`bool`)                                  | Whether descendants outside bounds are clipped.   |
| `LayoutTransform` / `RenderTransform`                    | Affects layout / paint-only respectively.         |

`HorizontalAlignment` / `VerticalAlignment` interact with `Width`/`Height`. If
`Width` is set, alignment controls positioning within the cell. If `Width` is `NaN`
and alignment is `Stretch`, the element fills the cell. If alignment is `Center` and
`Width` is `NaN`, the element sizes to content and is centred.

### Margin and Padding

`Thickness` is a 4-tuple: `Margin="left,top,right,bottom"`. Shorthand
`Margin="10"` is uniform; `Margin="10,5"` is horizontal-then-vertical. Margin is
applied _outside_ the element's render bounds -- it reduces the available size
passed to children. Padding is applied _inside_ controls (between the control's
border and its content) and is only available on `Control`, not on every
`FrameworkElement`.

### Visibility

The `Visibility` property has three values, two of which differ in layout impact:

- `Visible`: Element is rendered and participates in layout.
- `Hidden`: Element is _not_ rendered but _still occupies layout space_. The next
  Measure/Arrange pass returns its normal `DesiredSize` and reserves the space.
- `Collapsed`: Element is not rendered and is removed from layout. Its
  `DesiredSize` is `(0, 0)` and the layout shifts as if the element were not there.

This three-state visibility is one of WPF's most-replicated features -- web CSS has
`display: none` (collapsed) and `visibility: hidden`, mirroring the same distinction.

### Clipping

`ClipToBounds="True"` causes a panel to clip any descendants that try to draw
outside its bounds. The default depends on the panel: `Canvas` does not clip by
default (children may overflow), most others do not need to clip because their
arrange contracts already bound children.

### Logical vs Visual Tree

WPF maintains two parallel trees:

- **Logical tree.** The tree as expressed in XAML markup: a `Window` contains a
  `Grid`, which contains a `Button`, which contains a `TextBlock`.
- **Visual tree.** The expanded tree including template internals: the `Button`'s
  `Style` and `Template` introduce a `Border`, a `ContentPresenter`, and so on, all
  of which are visual children of the button.

Layout traverses the _visual_ tree, not the logical tree. This is important for
custom panels: when you override `MeasureOverride`, you walk `InternalChildren`,
which gives you the visual children including any data-bound items.

### Data Binding and Layout

WPF's data binding system feeds into layout. A `Width="{Binding ColumnWidth}"`
triggers a Measure invalidation when the bound property changes. An
`ItemsControl.ItemsSource="{Binding Records}"` triggers a full child-collection
update when the source collection changes. The binding pipeline calls into the
dependency-property system, which calls into the layout system, which schedules a
Measure pass on the dispatcher thread.

---

## Panels

`Panel` is the abstract base class of all layout containers. It exposes:

- `Children` -- the `UIElementCollection` of child elements (the logical children).
- `InternalChildren` -- includes data-bound items.
- `Background` -- a `Brush` to fill the panel's area.
- `Panel.ZIndex` -- attached property for z-ordering siblings.

The built-in panel set:

### Grid

The most powerful and most-used panel. Defines columns and rows with three sizing
modes:

- **Fixed pixel.** `Width="200"` -- the column is exactly 200 device-independent
  pixels.
- **Auto.** `Width="Auto"` -- the column sizes to fit its widest child's
  `DesiredSize`.
- **Star.** `Width="*"`, `Width="2*"` -- after fixed and auto columns are sized,
  the leftover width is divided among star columns proportional to their stars.

```xaml
<Grid>
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>  <!-- Sized to the widest child   -->
        <ColumnDefinition Width="*"/>     <!-- Gets 1 share of leftover     -->
        <ColumnDefinition Width="2*"/>    <!-- Gets 2 shares of leftover    -->
        <ColumnDefinition Width="100"/>   <!-- Exactly 100 pixels           -->
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Grid.Column="0" Text="Label:"/>
    <TextBox   Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="3"/>
    <ListBox   Grid.Row="1" Grid.ColumnSpan="4"/>
    <Button    Grid.Row="2" Grid.Column="3" Content="OK"/>
</Grid>
```

The star algorithm:

```
totalAvailable    = Grid's available width
totalFixed        = sum of fixed-pixel column widths
totalAuto         = sum of Auto-column children's max DesiredSize.Width
totalStars        = sum of star weights (e.g. 1 + 2 = 3)
leftover          = max(0, totalAvailable - totalFixed - totalAuto)
oneStarWidth      = leftover / totalStars

For each column:
  if fixed:  width = its pixel value
  if Auto:   width = max child DesiredSize.Width
  if star:   width = stars * oneStarWidth
```

Star sizing is what makes Grid uniquely good for forms: declare three columns as
`Auto, *, Auto` and you have label / stretchy-input / trailing-button -- the input
absorbs all extra space, the label and button hug their content. No imperative
math, no event handlers, just markup.

`Grid.RowSpan` and `Grid.ColumnSpan` extend a child across multiple cells.
`SharedSizeGroup` lets multiple Grids share `Auto`-column widths (so multiple stacked
forms align). `ShowGridLines="True"` is a debug aid that draws cell borders.

### StackPanel

Stacks children in a single line:

```xaml
<StackPanel Orientation="Vertical">
    <Button Content="One"/>
    <Button Content="Two"/>
    <Button Content="Three"/>
</StackPanel>
```

- `Orientation="Horizontal"` or `"Vertical"`.
- On the stacking axis, the panel is _constrained to content_ -- its size is the sum
  of children's desired sizes.
- On the perpendicular axis, the panel is _constrained_ to its parent and children
  stretch by default.
- StackPanel does not virtualise. For 10,000 items use `VirtualizingStackPanel`.

### DockPanel

Docks children to the edges of a container in declaration order:

```xaml
<DockPanel LastChildFill="True">
    <Menu       DockPanel.Dock="Top"/>
    <ToolBar    DockPanel.Dock="Top"/>
    <StatusBar  DockPanel.Dock="Bottom"/>
    <TreeView   DockPanel.Dock="Left" Width="200"/>
    <Border>    <!-- LastChildFill="True" -> fills remaining space. -->
        <ContentControl Content="{Binding CurrentView}"/>
    </Border>
</DockPanel>
```

The first child sized at top takes the full width and a strip of height equal to its
desired height. The next child occupies the space below it, and so on. The last
child fills whatever rectangle remains if `LastChildFill="True"` (the default).

This is the easiest way to express an Outlook-style "menu / toolbar / sidebar / main
content / status bar" shell layout.

### Canvas

Absolute positioning. Children declare their pixel offsets:

```xaml
<Canvas Width="400" Height="400">
    <Rectangle Canvas.Left="0"   Canvas.Top="0"   Width="100" Height="100" Fill="Red"/>
    <Rectangle Canvas.Left="100" Canvas.Top="100" Width="100" Height="100" Fill="Green"/>
    <Rectangle Canvas.Left="50"  Canvas.Top="50"  Width="100" Height="100" Fill="Blue"/>
</Canvas>
```

`Canvas.Left`, `Canvas.Top`, `Canvas.Right`, `Canvas.Bottom` are attached properties.
Canvas does no constraint propagation: it asks every child to measure with `Infinity`
in both dimensions and places them at their declared offsets. Useful for
draw-style applications, custom diagram editors, animation playgrounds.

By default Canvas does _not_ clip its children -- a Canvas with `Width="100"
Height="100"` will happily display a child at `Canvas.Left="500"`. Set
`ClipToBounds="True"` to change this.

### WrapPanel

A `StackPanel` that wraps to a new line when it runs out of room:

```xaml
<WrapPanel Orientation="Horizontal">
    <Button Content="Apple"/>
    <Button Content="Banana"/>
    <Button Content="Cherry"/>
    <Button Content="Damson"/>
    <Button Content="Elderberry"/>
</WrapPanel>
```

Each child takes its desired width; when the next child would overflow, the panel
moves to a new line. Useful for tag clouds, photo galleries, dynamic toolbar
overflow.

### UniformGrid

A grid where all cells are the same size:

```xaml
<UniformGrid Rows="2" Columns="3">
    <Button Content="1"/>
    <Button Content="2"/>
    <Button Content="3"/>
    <Button Content="4"/>
    <Button Content="5"/>
    <Button Content="6"/>
</UniformGrid>
```

No cell-by-cell sizing rules; every cell is `availableWidth / Columns` wide and
`availableHeight / Rows` tall. Children are placed in row-major order. Setting only
one of `Rows` or `Columns` lets the other dimension auto-compute.

### VirtualizingStackPanel

A `StackPanel` that only materialises children currently in the viewport. Used as
the default `ItemsPanel` for `ListBox`, `DataGrid`, `ComboBox`. Critical for any
list with more than a few hundred items.

### Custom Panels

To write a custom panel, inherit from `Panel` and override `MeasureOverride` and
`ArrangeOverride`. A custom panel can also expose its own attached properties to
control child behaviour, mirroring the `Grid.Row` / `DockPanel.Dock` pattern. See
Example 3 below for a full implementation.

---

## Code Examples

### Example 1: A Three-Pane Application Shell

Outlook-style "menu / sidebar / main content / status bar" layout:

```xaml
<Window x:Class="MyApp.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="My App" Height="600" Width="900">
    <DockPanel LastChildFill="True">
        <Menu DockPanel.Dock="Top">
            <MenuItem Header="_File">
                <MenuItem Header="_New"/>
                <MenuItem Header="_Open..."/>
                <Separator/>
                <MenuItem Header="E_xit"/>
            </MenuItem>
            <MenuItem Header="_Edit"/>
        </Menu>

        <StatusBar DockPanel.Dock="Bottom">
            <StatusBarItem><TextBlock Text="Ready"/></StatusBarItem>
            <Separator/>
            <StatusBarItem HorizontalAlignment="Right">
                <TextBlock Text="{Binding LineCount, StringFormat='Lines: {0}'}"/>
            </StatusBarItem>
        </StatusBar>

        <Border DockPanel.Dock="Left" Width="200" Background="#F0F0F0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Margin="8"
                           FontWeight="Bold" Text="Navigation"/>
                <TreeView Grid.Row="1" Margin="4"
                          ItemsSource="{Binding NavigationItems}"/>
            </Grid>
        </Border>

        <!-- Main content area (LastChildFill -> fills remaining space) -->
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" BorderBrush="Gray" BorderThickness="1" Margin="4">
                <TextBox Text="{Binding DocumentText}"
                         AcceptsReturn="True" AcceptsTab="True"
                         VerticalScrollBarVisibility="Auto"/>
            </Border>
            <StackPanel Grid.Row="1" Orientation="Horizontal"
                        HorizontalAlignment="Right" Margin="4">
                <Button Content="Cancel" Width="80" Margin="4,0"/>
                <Button Content="Save"   Width="80" Margin="4,0" IsDefault="True"/>
            </StackPanel>
        </Grid>
    </DockPanel>
</Window>
```

This example shows:

- DockPanel for the outer chrome: menu top, status bar bottom, sidebar left, body
  fills.
- Grid inside the sidebar for "title row above, content row stretches" pattern.
- Grid inside the body with `*` and `Auto` rows: the editor stretches, the button
  bar hugs.
- StackPanel for the right-aligned button row.
- Data binding for `LineCount`, `NavigationItems`, `DocumentText`.

### Example 2: A Form With Star Sizing

A login form that demonstrates the canonical `Auto, *` Grid pattern:

```xaml
<Grid Margin="20" MaxWidth="400">
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" SharedSizeGroup="Labels"/>
        <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Grid.Column="0" Margin="4"
               Text="Username:" VerticalAlignment="Center"/>
    <TextBox   Grid.Row="0" Grid.Column="1" Margin="4"
               Text="{Binding Username}"/>

    <TextBlock Grid.Row="1" Grid.Column="0" Margin="4"
               Text="Password:" VerticalAlignment="Center"/>
    <PasswordBox Grid.Row="1" Grid.Column="1" Margin="4"/>

    <CheckBox Grid.Row="2" Grid.Column="1" Margin="4"
              Content="Remember me" IsChecked="{Binding RememberMe}"/>

    <!-- Row 3 is `*`: a spacer that absorbs leftover vertical space -->

    <StackPanel Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="2"
                Orientation="Horizontal"
                HorizontalAlignment="Right" Margin="4">
        <Button Content="Cancel" Width="80" Margin="4,0" IsCancel="True"/>
        <Button Content="Log In" Width="80" Margin="4,0"
                IsDefault="True" Command="{Binding LogInCommand}"/>
    </StackPanel>
</Grid>
```

The structural points:

- Column 0 is `Auto` -- the column width equals the longest label.
- Column 1 is `*` -- the input column absorbs all remaining horizontal space.
- Rows 0-3 are `Auto` -- each row is the height of its content.
- Row 4 is `*` -- a vertical spacer that pushes the button bar to the bottom.
- Row 5 is `Auto` -- the button bar hugs its content.
- `SharedSizeGroup="Labels"` on column 0 lets you nest this Grid inside an outer
  `Grid.IsSharedSizeScope="True"` and have its `Auto` column width match other
  forms in the same scope.

### Example 3: A Custom Panel With Attached Properties

A `RadialPanel` that lays out children around a circle, controlled by per-child
angle attached properties:

```csharp
using System;
using System.Windows;
using System.Windows.Controls;

public class RadialPanel : Panel
{
    // Attached property: angle in degrees from north (0 = top, 90 = right).
    public static readonly DependencyProperty AngleProperty =
        DependencyProperty.RegisterAttached(
            "Angle", typeof(double), typeof(RadialPanel),
            new FrameworkPropertyMetadata(
                0.0, FrameworkPropertyMetadataOptions.AffectsParentArrange));

    public static void SetAngle(UIElement e, double v) => e.SetValue(AngleProperty, v);
    public static double GetAngle(UIElement e) => (double)e.GetValue(AngleProperty);

    public double Radius
    {
        get => (double)GetValue(RadiusProperty);
        set => SetValue(RadiusProperty, value);
    }

    public static readonly DependencyProperty RadiusProperty =
        DependencyProperty.Register(
            nameof(Radius), typeof(double), typeof(RadialPanel),
            new FrameworkPropertyMetadata(
                100.0, FrameworkPropertyMetadataOptions.AffectsArrange));

    protected override Size MeasureOverride(Size availableSize)
    {
        var unlimited = new Size(
            double.PositiveInfinity, double.PositiveInfinity);
        foreach (UIElement child in InternalChildren)
            child.Measure(unlimited);
        double diameter = Radius * 2;
        return new Size(diameter, diameter);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double cx = finalSize.Width / 2, cy = finalSize.Height / 2;
        foreach (UIElement child in InternalChildren)
        {
            double rad = (GetAngle(child) - 90) * Math.PI / 180;
            double x = cx + Radius * Math.Cos(rad) - child.DesiredSize.Width / 2;
            double y = cy + Radius * Math.Sin(rad) - child.DesiredSize.Height / 2;
            child.Arrange(new Rect(
                x, y, child.DesiredSize.Width, child.DesiredSize.Height));
        }
        return finalSize;
    }
}
```

Used in XAML:

```xaml
<local:RadialPanel Radius="120">
    <Ellipse Width="40" Height="40" Fill="Red"
             local:RadialPanel.Angle="0"/>
    <Ellipse Width="40" Height="40" Fill="Green"
             local:RadialPanel.Angle="90"/>
    <Ellipse Width="40" Height="40" Fill="Blue"
             local:RadialPanel.Angle="180"/>
    <Ellipse Width="40" Height="40" Fill="Yellow"
             local:RadialPanel.Angle="270"/>
</local:RadialPanel>
```

The example demonstrates the full panel-extension surface:

- An attached property (`Angle`) the child sets on itself; the panel reads it during
  `ArrangeOverride`.
- A regular dependency property on the panel (`Radius`) that affects arrange when
  changed.
- The `FrameworkPropertyMetadataOptions.AffectsParentArrange` flag on `Angle`: when
  a child changes its angle, the panel's arrange pass is invalidated automatically.

### Example 4: Visibility and Layout

Demonstrating the layout difference between `Collapsed` and `Hidden`:

```xaml
<Grid>
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Button Grid.Row="0" Content="Always visible"/>
    <Button Grid.Row="1" Content="Hidden (reserves space)"
            Visibility="Hidden"/>
    <Button Grid.Row="2" Content="Collapsed (no space)"
            Visibility="Collapsed"/>

    <TextBlock Grid.Row="3" VerticalAlignment="Top"
               Text="The first button is at the top.
                     The second is invisible but its row is the button's height.
                     The third is gone; no row for it.
                     This text starts directly below the (invisible) second button."/>
</Grid>
```

Use `Collapsed` for "I want this element to entirely disappear from the layout"
(default for `if`-style toggles bound to view-model state). Use `Hidden` for "I want
to make this invisible but keep my layout from jumping when it appears" (helpful for
tab content placeholders).

---

## Common Gotchas

### Auto-Sized Children Inside a `*` Column That's Too Small

If a Grid is given less available width than the sum of its `Auto` columns' desired
widths, the `Auto` columns shrink to whatever is available, then the star columns
get zero. Content may overflow visibly. Fix: set `MinWidth` on the auto column or
the child.

### StackPanel Inside a `*` Row

A `StackPanel` inside a Grid row sized `*` always sizes to content -- it will not
distribute the row's extra space among its children. Empty space appears at the
bottom. Fix: replace the outer StackPanel with another Grid.

### `Auto` in a ScrollViewer

A ScrollViewer passes `double.PositiveInfinity` on its scroll axis during Measure to
discover total content size. A `*` row or column inside a ScrollViewer collapses to
zero. Always use `Auto` or fixed sizes inside a ScrollViewer on the scroll axis.

### LayoutTransform vs RenderTransform

`RenderTransform` applies during paint and does not affect layout (rotated content
may overlap neighbours). `LayoutTransform` applies during measure and arrange and
does reflow the layout, at the cost of an extra layout pass. Use `RenderTransform`
for animations; `LayoutTransform` when you want layout to reflow.

### Sub-Pixel Edges

WPF uses 1/96-inch device-independent units. Pixel-perfect 1-pixel hairlines require
`UseLayoutRounding="True"` -- without it, sub-pixel positioning blurs edges.

### Performance Sinks

- Deeply nested `Grid`s with `Auto` columns trigger many recursive measure passes.
- `LayoutTransform` re-lays the entire subtree.
- `InvalidateMeasure` on every mouse-move destroys frame rate.
- Non-virtualising panels with thousands of children allocate visuals for everything.

---

## The XAML Lineage

WPF's layout model has been inherited, with minor variations, by every framework
Microsoft has built or sponsored since: Silverlight (2007), WinRT XAML (2012), UWP
(2015), Xamarin.Forms (2014), Avalonia (2016+), Uno Platform (2018+), WinUI 3
(2021), and .NET MAUI (2022). All share the two-pass Measure/Arrange protocol,
`Grid` with `Auto`/`*`/fixed sizing, `StackPanel` / `WrapPanel` / `Canvas`, attached
properties (`Grid.Row`, `Canvas.Left`, `DockPanel.Dock`), and the
`HorizontalAlignment` / `VerticalAlignment` / `Margin` / `Padding` quartet on every
element.

The most interesting member for cross-platform purposes is **Avalonia**, which has
demonstrated that the WPF layout protocol works equally well on macOS, Linux, iOS,
Android, and WebAssembly. In principle Avalonia could target a terminal backend,
treating each cell as a 1x1 device-independent pixel.

---

## Strengths and Weaknesses

### Strengths

- **Star sizing is uniquely ergonomic for forms.** The `Auto, *, Auto` Grid pattern
  expresses "label / stretchy input / trailing widget" in three column definitions,
  no event handlers, no calculations. Every other framework has copied this idea.
- **The Measure/Arrange protocol is clean and well-documented.** Microsoft's docs
  on the protocol are thorough; the conceptual model is small enough to fit on one
  page; the same protocol underpins six different frameworks.
- **Attached properties keep panels decoupled from children.** A `Grid` does not need
  to know what kinds of children it has; children carry their layout intent
  (`Grid.Row="2"`) on themselves. This makes `Grid` reusable across arbitrary content.
- **Excellent declarative markup.** XAML is verbose but readable; designer tools can
  round-trip it; data binding integrates directly. A complex shell layout can be
  expressed in a few hundred lines of markup.
- **Strong cross-framework portability.** The same layout knowledge works in WPF,
  Silverlight, UWP, MAUI, Avalonia, and Uno -- six frameworks that span Windows,
  macOS, Linux, iOS, Android, browser, and embedded targets.
- **Dependency property system integrates with layout.** Marking a property
  `AffectsMeasure` is all it takes to trigger correct invalidation. The framework
  guarantees that dirty propagation reaches the right elements.
- **Visibility tri-state.** `Visible` / `Hidden` / `Collapsed` is more expressive
  than CSS's two-state and avoids many layout-jump bugs.
- **Comprehensive built-in panel set.** Grid, StackPanel, DockPanel, WrapPanel,
  Canvas, UniformGrid, VirtualizingStackPanel cover essentially every desktop UI
  scenario without needing a custom panel.

---

### Weaknesses

- **XAML is verbose.** The same UI in Flutter Dart code can be half the size of the
  equivalent XAML. Closing tags, namespace declarations, attribute syntax, and
  property-element syntax all bloat the file.
- **Two passes cost roughly 2x layout time.** Flutter's single-pass protocol is
  measurably faster on cold layout. For thousands of elements, this matters.
- **Attached properties can be confusing.** `Grid.Row="2"` on a button works only
  inside a Grid; the property has no meaning elsewhere. Tooling helps, but it's
  unintuitive for newcomers.
- **LayoutTransform is expensive.** Any transform that affects the bounding box
  forces a layout pass; this is correct but easy to abuse.
- **Auto-sizing inside ScrollViewer is treacherous.** The most common WPF beginner
  bug is putting an `Auto` height inside a vertically-scrolling ScrollViewer and
  getting nothing.
- **Performance pitfalls scale with depth.** Deeply nested Grids with `Auto`
  columns/rows produce O(depth) measure passes; star sizing requires a second
  iteration. Recurring measure invalidations on every frame are catastrophic.
- **Static one-shot rendering is awkward.** Like Flutter, WPF assumes a continuous
  event loop. Rendering one frame to an offscreen surface and then exiting is
  possible but goes against the grain.
- **No first-class flex / wrap models.** Star sizing is great for grids; WrapPanel
  works for simple flows; but CSS Flexbox's `flex-grow` / `flex-shrink` /
  `flex-basis` triple, or grid-template-areas, have no direct analogue without
  combining multiple panels.

---

## Lessons for D / Sparkles

The WPF layout protocol translates well to terminal UIs, with one twist: the second
pass is largely free in a terminal context because the tree is small.

### Measure / Arrange Maps Cleanly to Static Terminal Layouts

A two-pass protocol is conceptually simple to implement in D:

```d
struct Size { ushort width, height; }
struct Rect { ushort x, y, width, height; }

interface IPanel {
    Size measure(Size available);   // Returns DesiredSize.
    void arrange(Rect finalRect);   // Positions self and children.
    Size desiredSize() const;
}
```

For a terminal table, the Measure pass walks every cell to find its desired width
and height (e.g., the length of its longest line); the Arrange pass distributes
leftover width among star columns and places each cell at its final coordinates.
For a small tree (dozens of cells), the cost of two passes is negligible.

### Star Sizing Is Just Constraint Arithmetic

Ratatui already has `Constraint::Fill(n)`, which is functionally identical to WPF's
`Width="n*"`. A D implementation could lift this into a richer DSL:

```d
enum ColumnWidth {
    auto_,           // Sized to widest content.
    fixed(ushort n), // n cells.
    star(double w),  // w shares of leftover.
}

struct Grid {
    ColumnWidth[] columns;
    ColumnWidth[] rows;
    Cell[][] cells;
}
```

The measure pass computes each `auto` column's max desired width; the arrange pass
distributes leftover among star columns.

### Attached Properties as UDAs

D's UDAs (User-Defined Attributes) could serve a similar role to WPF's attached
properties for static layout description:

```d
struct Row { ushort r; }
struct Column { ushort c; }

@Grid([1, "*", 1])
struct LoginForm {
    @Row(0) @Column(0) Label usernameLabel;
    @Row(0) @Column(1) TextBox username;
    @Row(1) @Column(0) Label passwordLabel;
    @Row(1) @Column(1) TextBox password;
}
```

A template-based renderer can introspect these UDAs at compile time, eliminating
all runtime indirection. Compile-time errors catch mistakes like out-of-bounds row
indices.

### CTFE Pre-Computes Static Layouts

For static dashboards where the layout is known at compile time, D's CTFE can
collapse the entire Measure/Arrange protocol into compile-time constants:

```d
enum dashboardLayout = grid([
    columnDef!Auto,
    columnDef!"*",
    columnDef!(40),
], [
    rowDef!"Auto",
    rowDef!"*",
    rowDef!"Auto",
]).measure(Size(80, 24)).arrange(Rect(0, 0, 80, 24));
```

This is something WPF cannot do because everything depends on runtime DPI, font
metrics, and window size. For terminals, none of that matters.

### Avalonia-Inspired Cross-Backend Strategy

Avalonia proved the Measure/Arrange protocol works on every platform. A Sparkles
layout sub-package could target multiple backends (terminal, SDL, in-memory test)
because the protocol itself is backend-agnostic -- only the paint phase differs.

---

## References

- **WPF Layout (the foundational article):**
  <https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/layout>
- **Panels Overview:**
  <https://learn.microsoft.com/en-us/dotnet/desktop/wpf/controls/panel>
- **Alignment, Margins, and Padding:**
  <https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/alignment-margins-and-padding-overview>
- **API Reference:**
  - `FrameworkElement.MeasureOverride`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.frameworkelement.measureoverride>
  - `FrameworkElement.ArrangeOverride`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.frameworkelement.arrangeoverride>
  - `UIElement.Measure`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.uielement.measure>
  - `UIElement.Arrange`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.uielement.arrange>
  - `Panel`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.panel>
  - `Grid`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.grid>
  - `DockPanel`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.dockpanel>
  - `StackPanel`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.stackpanel>
  - `WrapPanel`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.wrappanel>
  - `Canvas`:
    <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.canvas>
- **The XAML lineage:**
  - WPF source: <https://github.com/dotnet/wpf>
  - Avalonia: <https://avaloniaui.net/>
  - Uno Platform: <https://platform.uno/>
  - .NET MAUI: <https://learn.microsoft.com/en-us/dotnet/maui/>
- **Cross-reference:**
  - Flutter (single-pass constraint protocol):
    [./flutter.md](./flutter.md)
  - Ratatui (Rust TUI, immediate-mode constraint solver):
    [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)
  - Ink (JS TUI, retained-mode Flexbox):
    [../tui-libraries/ink.md](../tui-libraries/ink.md)
