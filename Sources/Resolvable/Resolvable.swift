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
    // Compile-time only; never read at runtime.
    public var wrappedValue: Value {
        get { fatalError("Overridable is compile-time only") }
        set { fatalError("Overridable is compile-time only") }
    }

    public init() {}

    // @Overridable(\Root.leaf)
    public init(_ keyPath: AnyKeyPath) {}

    // @Overridable(\Root.leaf, as: Leaf.self)
    public init(_ keyPath: AnyKeyPath, as: Any.Type) {}

    // Labeled variant, if you prefer: @Overridable(keyPath: \Root.leaf, as: Leaf.self)
    public init(keyPath: AnyKeyPath, as: Any.Type? = nil) {}
}
