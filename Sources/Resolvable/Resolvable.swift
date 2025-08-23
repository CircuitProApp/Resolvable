// The Swift Programming Language
// https://docs.swift.org/swift-book

/// The `@Resolvable` macro generates all the necessary boilerplate for the
/// definition/instance/override/resolved pattern.
@attached(
    member,
    names:
        named(Definition),
        named(Instance),
        named(Override),
        named(Resolved),
        named(Source),
        named(Resolver),
        named(init)
)
@attached(memberAttribute)
public macro Resolvable() = #externalMacro(module: "ResolvableMacros", type: "ResolvableMacro")

/// A property wrapper to mark which properties of a model can be
/// overridden by an instance. This wrapper does nothing at runtime; it is
/// only a marker for the `@Resolvable` macro to detect.
@propertyWrapper
public struct Overridable<Value> {
    public let keyPath: AnyKeyPath?
    public let leafType: Any.Type?
    public var wrappedValue: Value

    // Whole-property overrides (default and memberwise init use this)
    public init(wrappedValue: Value) {
        self.keyPath = nil
        self.leafType = nil
        self.wrappedValue = wrappedValue
    }

    // Unlabeled key-path form: @Overridable(\Root.leaf, as: ...)
    public init(wrappedValue: Value, _ keyPath: AnyKeyPath, as leafType: Any.Type? = nil) {
        self.keyPath = keyPath
        self.leafType = leafType
        self.wrappedValue = wrappedValue
    }

    // Labeled key-path form: @Overridable(keyPath: \Root.leaf, as: ...)
    public init(wrappedValue: Value, keyPath: AnyKeyPath, as leafType: Any.Type? = nil) {
        self.keyPath = keyPath
        self.leafType = leafType
        self.wrappedValue = wrappedValue
    }
}
