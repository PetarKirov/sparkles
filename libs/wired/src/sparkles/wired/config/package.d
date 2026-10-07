/**
Retained configuration definitions, typed collection composition, and JSON input.

The schema owns defaults and validation; sources carry definition priority and
order. Resolution preserves every definition and returns an inspectable snapshot,
including conflicts, without choosing a winner by submission order.

The same snapshot inspects root definitions, generated defaults, and original
branch projections without replacing provenance with normalized values.
*/
module sparkles.wired.config;

public import sparkles.wired.config.core;
public import sparkles.wired.config.json;
public import sparkles.wired.config.payload : ConfigPresence, fullPresence;
public import sparkles.wired.config.metadata : ConfigBranchMetadata,
    CollectionDefinitionMetadata, fullBranchMetadata;
public import sparkles.wired.config.borrow : ConfigArrayValueView, ConfigMapValueView,
    ConfigStructMembersView, ConfigStructValueView, ConfigPresenceView;
