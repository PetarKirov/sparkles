/**
Retained scalar configuration definitions and original-policy JSON input.

The schema owns defaults and validation; sources carry definition priority and
order. Resolution preserves every definition and returns an inspectable snapshot,
including conflicts, without choosing a winner by submission order.

Import this module for the C1 scalar interface. Collection composition and report
presentation have separate contracts and are not implemented by this package.
*/
module sparkles.wired.config;

public import sparkles.wired.config.core;
public import sparkles.wired.config.json;
