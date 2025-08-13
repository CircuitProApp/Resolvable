// The Swift Programming Language
// https://docs.swift.org/swift-book

/// The `@Resolvable` macro generates all the necessary boilerplate for the
/// definition/instance/override/resolved pattern.
@attached(peer, names: arbitrary)
@attached(
    extension,
    names:
        named(Definition),
        named(Instance),
        named(Override),
        named(Resolved),
        named(Source),
        named(Resolver)
)
public macro Resolvable() = #externalMacro(module: "ResolvableMacroMacros", type: "ResolvableMacro")

/// A property wrapper to mark which properties of a model can be
/// overridden by an instance. This wrapper does nothing at runtime; it is
/// only a marker for the `@Resolvable` macro to detect.
@propertyWrapper
public struct Overridable<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
