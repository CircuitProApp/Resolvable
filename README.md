# Resolvable

A Swift macro package that generates the boilerplate for a “definition / instance / override / resolved” data-model pattern. Mark a struct with `@Resolvable` and annotate any fields you want to be overridable with the `@Overridable` property wrapper. The macro synthesizes strongly-typed nested types and a resolver so you can merge definitions, per-definition overrides, and ad-hoc instances into a unified “resolved” view model.

- Zero runtime magic: the macro generates plain Swift you can read.
- Clear type boundaries: `Definition`, `Instance`, `Override`, `Resolved`, `Source`, and `Resolver`.
- Safety by construction: you cannot instantiate the base type directly (see “About the ghost initializer” below).

## Requirements

- Swift 5.9+ (macros)
- Xcode 16+ (for Apple platforms)

## Installation

In Xcode: File > Add Packages… and paste the repository URL.

## Quick start

```swift
import Resolvable

@Resolvable
struct Product {
    @Overridable var title: String
    var sku: String
    @Overridable var price: Decimal
    var isActive: Bool

    // Nested leaf override: explicit root + explicit leaf type
    @Overridable(\Shipping.carrier, as: String.self)
    var shipping: Shipping
}

struct Shipping: Codable, Hashable, Equatable {
    var weight: Double
    var carrier: String
}
```

The macro synthesizes:

- `Product.Definition`: canonical shape for definitions (`Identifiable`, `Codable`, `Hashable`).
- `Product.Instance`: ad‑hoc shape for instances (`Identifiable`, `Codable`, `Hashable`).
- `Product.Override`: optional overrides only for `@Overridable` fields (`Identifiable`, `Codable`, `Hashable`).
- `Product.Source`: provenance of a resolved item (`Hashable`).
- `Product.Resolved`: the read-model with merged values (`Identifiable`, `Hashable`).
- `Product.Resolver`: performs the merge.

### What `Override` looks like

For the `Product` above, `Override` includes:

- Whole-property overrides for `title` and `price`:
  - `title: String?`
  - `price: Decimal?`
- Nested leaf override for `shipping.carrier`, emitted as `shipping_carrier: String?`

```swift
public struct Product.Override: Identifiable, Codable, Hashable {
    public let definitionID: UUID
    public var id: UUID { definitionID }

    public var title: String?
    public var price: Decimal?
    public var shipping_carrier: String?

    public init(definitionID: UUID,
                title: String? = nil,
                price: Decimal? = nil,
                shipping_carrier: String? = nil) {
        self.definitionID = definitionID
        self.title = title
        self.price = price
        self.shipping_carrier = shipping_carrier
    }
}
```

### Merge rules

- Definitions:
  - For each `@Overridable` field, if an override exists, use it; otherwise use the definition’s value.
  - For nested overrides, the macro mutates a copy of the nested struct (no need to call its memberwise init).
- Instances:
  - Passed through as-is (no overrides applied).
- The result preserves provenance via `Product.Source`.

---

## Using `@Overridable`

Accepted forms:

- Whole property:
  - `@Overridable var title: String`
- Nested leaf (explicit root and explicit leaf type are required):
  - `@Overridable(\Root.leaf, as: LeafType.self)`
  - Example: `@Overridable(\Shipping.carrier, as: String.self)`

Rules:

- The key path must use an explicit root (e.g. `\Shipping.carrier`). Rootless paths like `\.carrier` are rejected with a diagnostic.
- The `as:` leaf type is required. This keeps `Override` strongly typed and able to synthesize `Codable/Hashable/Equatable`.
- Nested override fields are emitted as `parent_leaf` (e.g. `shipping_carrier`).

Diagnostics:

- Missing key path: “@Overridable requires a key-path (e.g. @Overridable(\Shipping.carrier, as: String.self))”
- Rootless key path: “Use an explicit root in key path (e.g. \Shipping.carrier). Rootless paths (\.carrier) are not allowed.”
- Missing leaf type: “Provide leaf type with ‘as: <Type>.self’”

---

## What gets generated (overview)

- `struct <Base>.Definition`: `Identifiable`, `Codable`, `Hashable`
  - `var id: UUID = UUID()`
  - Stored properties cloned from the base type (wrapper removed).

- `struct <Base>.Instance`: `Identifiable`, `Codable`, `Hashable`
  - `var id: UUID = UUID()`
  - Same property set as `Definition`.

- `struct <Base>.Override`: `Identifiable`, `Codable`, `Hashable`
  - `let definitionID: UUID`
  - Optional properties only for fields marked `@Overridable`
  - Nested leafs emitted as `parent_leaf: <LeafType>?`
  - `var id: UUID { definitionID }`

- `enum <Base>.Source`: `Hashable`
  - `.definition(definitionID: UUID)` and `.instance(instanceID: UUID)`

- `struct <Base>.Resolved`: `Identifiable`, `Hashable`
  - `let source: Source`
  - All properties as `var` (even if the original was `let`)
  - `var id: UUID` derived from `source`

- `struct <Base>.Resolver`
  - `static func resolve(definitions: [Definition], overrides: [Override], instances: [Instance]) -> [Resolved]`
  - Applies whole-property overrides directly, and nested overrides by mutating a local copy of the nested struct.

---

## About the “ghost initializer” (why you can’t construct the base type)

The macro injects an initializer on the base type that is annotated as unavailable and calls `fatalError`, and marks any user-declared initializers unavailable as well. This intentionally prevents calling the base type’s memberwise initializer and guides you to use the nested types instead. For background on Swift’s memberwise initializer behavior, see the glossary entry on the “Memberwise initializer” [hackingwithswift.com](https://www.hackingwithswift.com/glossary).

Use these instead:

- `YourType.Definition` for canonical data
- `YourType.Instance` for ad-hoc items
- `YourType.Override` for per-definition overrides

---

## Codable / Hashable notes

- `Definition`, `Instance`, and `Override` conform to `Codable` and `Hashable`.
- Nested leaf fields must have concrete types that are themselves `Codable`/`Hashable`. If you introduce a non‑codable leaf type, you’ll need to remove `Codable` from `Override` (or add custom encoding).
- Be aware of general `Codable` caveats when mixing synthesized coding with defaulted or computed members (see discussion and workarounds in Apple developer forums) [developer.apple.com](https://developer.apple.com/forums/thread/763667).

---

## Limitations

- `@Resolvable` applies to `struct` types only.
- Only stored properties without accessors are included. Members with accessor blocks are ignored.
- Macros operate on syntax, not types; the macro requires you to specify the leaf type with `as: <Type>.self` for nested leaf overrides.
- `Resolved` is not `Codable` by default. If you need it to be codable, you can fork and add conformance to the generated type, but consider how to encode `source`.

---

## FAQ

- Why explicit `as: <Type>.self` for nested leafs?
  - To keep generated `Override` fields strongly typed and codable/hashable without fragile type inference.
- Can I shorten `as: String.self` further?
  - You can add your own helper (in your app/library) such as:
    ```swift
    postfix operator ^
    public postfix func ^<Root, Value>(kp: KeyPath<Root, Value>) -> Value.Type { Value.self }
    // @Overridable(\Shipping.carrier, as: (\Shipping.carrier)^)
    ```
  - We keep the macro’s requirement explicit and stable.

---

## License

MIT
