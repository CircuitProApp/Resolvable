# Resolvable

A Swift macro package that generates the boilerplate for a “definition / instance / override / resolved” data-model pattern. Mark a struct with `@Resolvable` and annotate any fields you want to be overridable with the `@Overridable` property wrapper. The macro synthesizes strongly-typed nested types and a resolver so you can merge definitions, per-definition overrides, and ad-hoc instances into a unified “resolved” view model.

- Zero runtime magic: the macro generates plain Swift code you can read.
- Clear type boundaries: `Definition`, `Instance`, `Override`, `Resolved`, `Source`, and `Resolver`.
- Safety by construction: you cannot instantiate the base type directly (see “About the ghost initializer” below).

## Requirements

- Swift 5.9+ (macros)
- Xcode 16+ (for Apple platforms)

Macros are implemented using SwiftSyntax/SwiftSyntaxBuilder and attached macro APIs introduced to Swift 5.9. For background, see Swift’s macro pitch and syntax builder notes on the Swift Forums:
- Attached macros pitch: [forums.swift.org](https://forums.swift.org/t/pitch-attached-macros/62812)
- SwiftSyntaxBuilder announcement: [forums.swift.org](https://forums.swift.org/t/announcing-swiftsyntaxbuilder/56565)

## Installation

In Xcode: File > Add Packages… and paste your package URL.

## Quick start

```swift
import Resolvable

@Resolvable
struct Product {
    @Overridable var title: String
    var sku: String
    @Overridable var price: Decimal
    var isActive: Bool
}
```

That’s it. The macro synthesizes:

- `Product.Definition`: canonical data shape for definitions (`Identifiable`, `Codable`, `Hashable`).
- `Product.Instance`: ad-hoc shape for instances (`Identifiable`, `Codable`, `Hashable`).
- `Product.Override`: per-definition, optional overrides for `@Overridable` fields (`Identifiable`, `Codable`, `Hashable`).
- `Product.Source`: tells whether a resolved item came from a definition or instance (`Hashable`).
- `Product.Resolved`: the read-model with merged values (`Identifiable`, `Hashable`).
- `Product.Resolver`: performs the merge.

---

## What gets generated

Given:

```swift
@Resolvable
struct Thing {
    @Overridable var name: String
    var count: Int
}
```

The macro generates (high-level overview):

- **`struct Thing.Definition`: Identifiable, Codable, Hashable**
  - `var id: UUID = UUID()`
  - `let`/`var` stored properties cloned from `Thing` (minus the `@Overridable` wrapper).

- **`struct Thing.Instance`: Identifiable, Codable, Hashable**
  - `var id: UUID = UUID()`
  - Same property set as `Definition`.

- **`struct Thing.Override`: Identifiable, Codable, Hashable**
  - `let definitionID: UUID`
  - Optional properties only for fields marked `@Overridable` (e.g., `name: String?`)
  - `var id: UUID { definitionID }`

- **`enum Thing.Source`: Hashable**
  - `.definition(definitionID: UUID)`
  - `.instance(instanceID: UUID)`

- **`struct Thing.Resolved`: Identifiable, Hashable**
  - `let source: Source`
  - All properties as `var` (even if original was `let`)
  - `var id: UUID` derived from `source`

- **`struct Thing.Resolver`**
  - `static func resolve(definitions: [Definition], overrides: [Override], instances: [Instance]) -> [Resolved]`

**Merge rules**:
- For each definition, if an override exists for an overridable field, use it; otherwise use the definition’s value.
- Instances are copied through as-is.
- The result preserves provenance via `source`.

**Notes**:
- Only stored properties without accessors are included. Computed properties or ones with explicit accessors are ignored.
- The macro strips the `@Overridable` wrapper from synthesized nested types—it's purely a marker and has no runtime behavior in your models.


### About the “ghost initializer” (direct init won’t work)

You cannot instantiate the base type that’s annotated with `@Resolvable`. The macro intentionally:

- Injects an initializer on the base type that is annotated as unavailable and calls `fatalError` to make direct construction impossible.
- Marks any user-declared initializers inside the annotated type as unavailable.

This “blocks” both the synthesized memberwise initializer and any custom initializers, guiding you to use the nested types instead:

- Use `YourType.Definition` for canonical data.
- Use `YourType.Instance` for ad-hoc items.
- Use `YourType.Override` to override only the fields you marked as `@Overridable`.

Attempting to call `YourType(...)` will produce a compile-time error.

---

## Design constraints and behavior

- **Supported declarations**: `@Resolvable` can be applied to structs only.
- **Stored properties only**: members with accessor blocks are ignored.
- **Mutability** is preserved in nested `Definition`/`Instance`, but `Resolved` uses `var` for all fields, enabling post-merge adjustments if desired.

**Identity**:
- `Definition` and `Instance` carry their own `id: UUID` (defaulted to a random UUID; override if you need stable IDs).
- `Resolved.id` equals the `definitionID` or `instanceID` depending on source.
- `Override.id == definitionID`.

**Codable**:
- `Definition`, `Instance`, and `Override` conform to `Codable`.
- `Resolved` and `Source` are **not** `Codable` by default (but `Source` is `Hashable`). Adjust as needed in your project if you fork.

---

## Tips and gotchas

- If you need an overridable field, wrap it with `@Overridable`. Otherwise it won’t appear in `Override`.
- If you declare any custom initializers inside the annotated type, they’ll be marked unavailable anyway; put your construction logic on the nested types or introduce factory helpers outside the base type.
- When resolving, overrides are matched by `definitionID`. Make sure you pass the correct `id` when creating overrides.
