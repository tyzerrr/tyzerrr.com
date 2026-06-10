---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'CSS layout notes from building a header'
pubDate: 2026-06-11
description: 'A systematic summary of Tailwind CSS layout, spacing, flexbox, inputs and theme colors learned while building a header'
author: 'tyzerrr'
---

# CSS layout notes from building a header

Today I worked through a small but useful UI: a header with a logo, menu, search box, cart icon, user icon, and a footer layout.

The interesting part was not the final UI itself.
The useful part was understanding what Tailwind CSS classes actually mean, especially around width, flexbox, spacing, input styling, and theme colors.

This is my systematic summary.

## `w-full` means parent width, not screen width

The first trap was assuming this:

```tsx
<div className="w-full">
```

means:

> Fill the browser width.

That is not quite right.
`w-full` means:

> Fill the width of the parent element.

So if the parent is only as wide as its content, the child will also only become that wide.

This matters in headers and search boxes.
For example:

```tsx
<div className="flex items-center gap-6">
  <Search />
  <Cart />
</div>
```

This parent does not automatically fill the browser.
It only takes the width needed by `Search` and `Cart`.
So if `Search` has `w-full`, it fills this small parent, not the whole screen.

The mental model:

```txt
w-full = 100% of the parent
not always 100% of the viewport
```

If I want an element to have real room, I need to give either the element or one of its parents a meaningful width:

```tsx
<div className="w-80">
```

or:

```tsx
<div className="w-full">
```

only when its parent is already full-width.

## `justify-between` only works when there is extra space

Another trap was `justify-between`.

I expected this:

```tsx
<div className="flex w-full justify-between">
  <SearchIcon />
  <p>Search products...</p>
</div>
```

to always push the icon and text to both ends.

But `justify-between` does not create width.
It only distributes unused space between children.

If the parent is 400px wide:

```txt
| icon ----------------------------- text |
```

But if the parent is only as wide as the icon plus text:

```txt
| icon text |
```

there is no extra space to distribute.

So `justify-between` is not broken.
The parent simply has no spare space.

For a search box, I usually do not want `justify-between` anyway.
I want the icon and text/input to sit together on the left:

```tsx
<div className="flex w-80 items-center gap-3 rounded-full bg-primary-dark px-6 py-3">
  <SearchIcon className="size-5 text-gray-400" />
  <input className="min-w-0 flex-1 bg-transparent focus:outline-none" />
</div>
```

The important class is `gap-3`.
It keeps the children left-aligned while adding space between them.

## Padding creates inner space

To add space inside a header, I should use padding:

```tsx
<header className="flex w-full items-center justify-between px-6 py-3">
```

`px-6` means horizontal padding.
`py-3` means vertical padding.

The difference:

```txt
px-* = left and right inner space
py-* = top and bottom inner space
```

This is how to make a full-width header avoid touching the browser edges.

## Rounded shapes

For a pill-shaped search box or button:

```tsx
<div className="rounded-full">
```

If the element is a square, `rounded-full` makes it a circle.
If the element is wider than tall, it becomes a pill.

Examples:

```tsx
<div className="h-10 w-10 rounded-full" />
```

is a circle.

```tsx
<div className="h-10 w-80 rounded-full" />
```

is a pill.

## Text size, text color and font weight

Tailwind uses `text-*` for font size:

```tsx
<p className="text-sm">Small</p>
<p className="text-lg">Large</p>
<p className="text-2xl">Bigger</p>
```

It also uses `text-*` for text color:

```tsx
<p className="text-gray-400">Muted text</p>
<p className="text-primary">Primary text</p>
```

This can be confusing at first because both size and color start with `text-`.
The meaning depends on the token after it.

Font weight uses `font-*`:

```tsx
<p className="font-light">Light text</p>
<p className="font-bold">Bold text</p>
```

For helper functions, a default value can be handled in TypeScript with `??`:

```ts
function footerLight(fontSize?: string | null): string {
  const size = fontSize ?? "text-sm";
  return `font-light font-serif text-ink3 ${size}`;
}
```

`??` means:

```txt
Use the right side only when the left side is null or undefined.
```

## Icons are React components

With `lucide-react`, icons are imported and used as React components:

```tsx
import { Search, ShoppingCart, User } from "lucide-react";
```

Then:

```tsx
<Search className="size-5 text-gray-400" />
<ShoppingCart className="size-6 text-gray-700" />
<User className="size-6 text-gray-700" />
```

The icon size and color are controlled with Tailwind classes, just like text.

If a local component is also named `Search`, I should use an alias:

```tsx
import { Search as SearchIcon } from "lucide-react";
```

## Inputs inside flex containers need `flex-1`

When I put an input inside a search box, the input did not fill the available yellow area.

The fix:

```tsx
<input className="min-w-0 flex-1 bg-transparent focus:outline-none" />
```

`flex-1` means:

> Use the remaining available space.

So in this layout:

```tsx
<div className="flex w-80 items-center gap-3">
  <SearchIcon />
  <input className="flex-1" />
</div>
```

the icon uses its own width, and the input uses the rest.

`min-w-0` is also important in flex layouts.
By default, flex children sometimes refuse to shrink below their content size.
`min-w-0` says:

> This element is allowed to shrink if needed.

So the stable pattern for an input inside flex is:

```tsx
<input className="min-w-0 flex-1" />
```

For search UI, `bg-transparent` makes the input blend into the wrapper background:

```tsx
<input className="min-w-0 flex-1 bg-transparent focus:outline-none" />
```

## Border, outline and ring are different

I also learned the difference between border, outline, and ring.

`border` is the normal visible border:

```tsx
<div className="border border-primary-line">
```

`border-primary-line` only sets the color.
It does not create the border by itself.
So this is incomplete:

```tsx
<div className="border-primary-line">
```

The correct version is:

```tsx
<div className="border border-primary-line">
```

For focus styling, I can use `focus:outline-none` on the input:

```tsx
<input className="focus:outline-none" />
```

If I want the whole search box to react when the input is focused, I can style the parent with `focus-within`:

```tsx
<div className="border border-primary-line focus-within:ring-2 focus-within:ring-primary-line">
  <input className="focus:outline-none" />
</div>
```

`focus-within` means:

> Apply this style when any child element is focused.

That is perfect for a search box wrapper.

## Defining theme colors in Tailwind CSS v4

In Tailwind CSS v4, custom colors can be defined with `@theme`.

Example:

```css
@import "tailwindcss";

@theme {
  --color-primary: #f6f5f2;
  --color-primary-dark: #efede8;
  --color-primary-line: #e6e3dc;
}
```

Then I can use:

```tsx
<header className="bg-primary">
```

```tsx
<div className="bg-primary-dark border border-primary-line">
```

The mapping is:

```txt
--color-primary      -> bg-primary, text-primary, border-primary
--color-primary-line -> bg-primary-line, text-primary-line, border-primary-line
```

One important detail:

```css
--color-primary-line: e6e3dc;
```

is wrong because it is missing `#`.

It must be:

```css
--color-primary-line: #e6e3dc;
```

Also, `primary` only means whatever I define.
It is not automatically blue or black or brand-colored.
If `bg-primary` looks black, I should check what value `--color-primary` actually has, or whether the text/icon color is what I am seeing.

## Header and footer placement

For normal page layout, `fixed` is not the first tool I should reach for.

If I simply want:

```txt
Header at the top
Footer at the bottom
Main content in between
```

then this layout is better:

```tsx
<body className="flex min-h-screen flex-col">
  <Header />
  <main className="flex-1">{children}</main>
  <Footer />
</body>
```

The key classes:

```txt
flex flex-col  -> stack children vertically
min-h-screen   -> body is at least viewport height
flex-1         -> main takes the remaining space
```

`flex` is not only for horizontal layout.
By default it lays children horizontally, but `flex-col` changes the main axis to vertical.

So in a column flex container:

```tsx
<main className="flex-1">
```

means:

> Main grows vertically and pushes the footer down.

Use `fixed` only when the element must stay on screen while scrolling:

```tsx
<header className="fixed top-0 w-full">
```

For headers that should stick after scrolling, `sticky` is often a better choice:

```tsx
<header className="sticky top-0 z-50">
```

## `min-h-screen` and `min-h-full`

`min-h-screen` is based on the viewport:

```txt
min-h-screen = min-height: 100vh
```

So it means:

> At least as tall as the browser screen.

`min-h-full` is based on the parent:

```txt
min-h-full = min-height: 100%
```

So it only works as expected when the parent already has a defined height.

For simple page layouts, `min-h-screen` is usually easier to reason about.

## Aligning vertical lists

When multiple vertical lists are placed side by side and they have different numbers of children, their first items can appear at different Y positions if the parent uses vertical centering.

Wrong for top alignment:

```tsx
<div className="flex items-center gap-8">
```

Better:

```tsx
<div className="flex items-start gap-8">
```

`items-start` aligns the top edge of each list.

Each list can then be:

```tsx
<div className="flex flex-col gap-3">
```

The pattern:

```txt
parent: items-start
list: flex flex-col gap-*
```

## Rules I want to remember

- `w-full` fills the parent, not necessarily the browser.
- `justify-between` only spreads items when the parent has extra space.
- Use `gap-*` when items should stay together but have spacing.
- Use `px-*` and `py-*` for inner spacing.
- Use `rounded-full` for circles and pill shapes.
- Use `flex-1` when a flex child should use remaining space.
- Use `min-w-0` for inputs or long text inside flex containers.
- Use `border border-color`, not only `border-color`.
- Use `focus-within:*` when a wrapper should respond to a focused child.
- Define Tailwind v4 custom colors with `@theme` and `--color-*`.
- Do not forget `#` in hex colors.
- For normal header/main/footer layout, prefer `flex min-h-screen flex-col` over `fixed`.

The big lesson is that most CSS problems are not random.
They come from a few core questions:

- What is the parent size?
- Which axis is flex using?
- Is there actually extra space to distribute?
- Am I styling the element itself or its wrapper?
- Is this class creating a thing, or only coloring an existing thing?

Once those questions are clear, Tailwind classes become much easier to predict.
