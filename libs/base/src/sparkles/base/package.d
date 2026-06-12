/**
Core allocation-conscious utilities shared by Sparkles packages.

Importing `sparkles.base` brings in the small-buffer, lifetime, text,
styling, styled-IES, and logging primitives.
*/
module sparkles.base;

public import sparkles.base.lifetime;
public import sparkles.base.logger;
public import sparkles.base.smallbuffer;
public import sparkles.base.styled_template;
public import sparkles.base.term_style;
public import sparkles.base.text;
