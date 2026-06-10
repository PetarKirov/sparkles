---
layout: home

hero:
  name: Sparkles
  text: CLI Utilities for D
  tagline: Terminal styling, pretty-printing, TUI components, and @nogc support for building beautiful command-line applications.
  actions:
    - theme: brand
      text: Get Started
      link: /overview
    - theme: alt
      text: View on GitHub
      link: https://github.com/PetarKirov/sparkles

features:
  - title: base
    details: 'Allocation-conscious foundation modules: SmallBuffer, @nogc text readers and writers, terminal styling, styled templates, and CoreLogger.'
  - title: core-cli
    details: 'CLI argument parsing, pretty-printing for any D type, process helpers, terminal helpers, and UI components (tables, boxes, headers).'
  - title: terminal
    details: A minimal, fast terminal emulator built on libghostty-vt — Ghostty's VT engine — with Kitty graphics, hyperlinks, and a GC-pause-free render loop.
    link: /apps/terminal/
---
