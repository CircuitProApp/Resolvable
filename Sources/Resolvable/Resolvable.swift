// The Swift Programming Language
// https://docs.swift.org/swift-book

// Default behavior for properties inside a @Resolvable struct
public enum ResolvableDefault {
    case optIn         // Only properties marked @Overridable are overridable
    case overridable   // All properties are overridable unless marked @Identity
}

/// Defines the pattern of code generation for a @Resolvable type.
public enum ResolvablePattern {
    /// Generates `.Definition`, `.Instance`, and `.Override`.
    case full

    /// Generates only `.Definition` and `.Override`.
    case nonInstantiable
}

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
public macro Resolvable(
    default: ResolvableDefault = .optIn,
    pattern: ResolvablePattern = .full
) = #externalMacro(module: "ResolvableMacros", type: "ResolvableMacro")

/// A property wrapper to mark which properties of a model can be
/// overridden by an instance. This wrapper does nothing at runtime; it is
/// only a marker for the `@Resolvable` macro to detect.
@propertyWrapper
public struct Overridable<Value> {
    public let keyPath: AnyKeyPath?
    public let leafType: Any.Type?

    // Compile-time only; the base type annotated with @Resolvable is not meant to be instantiated.
    public var wrappedValue: Value {
        get { fatalError("Overridable is compile-time only") }
        set { fatalError("Overridable is compile-time only") }
    }

    // 1) No-arg: @Overridable var x: T
    public init() {
        self.keyPath = nil
        self.leafType = nil
    }

    // 2) Args-only: @Overridable(\Root.leaf, as: Leaf.self) var x: Root
    public init(_ keyPath: AnyKeyPath, as leafType: Any.Type? = nil) {
        self.keyPath = keyPath
        self.leafType = leafType
    }

    // 3) wrappedValue only: @Overridable var x: T = default
    public init(wrappedValue: Value) {
        self.keyPath = nil
        self.leafType = nil
    }

    // 4) wrappedValue + args: @Overridable(\Root.leaf, as: Leaf.self) var x: Root = default
    public init(wrappedValue: Value, _ keyPath: AnyKeyPath, as leafType: Any.Type? = nil) {
        self.keyPath = keyPath
        self.leafType = leafType
    }

    // Optional labeled variant
    public init(wrappedValue: Value, keyPath: AnyKeyPath, as leafType: Any.Type? = nil) {
        self.keyPath = keyPath
        self.leafType = leafType
    }
}

/// A property wrapper to mark which properties of a model can not be
/// overridden. This wrapper does nothing at runtime; it is
/// only a marker for the `@Resolvable` macro to detect.
@propertyWrapper
public struct Identity<Value> {
    private var value: Value

    public init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    public var wrappedValue: Value {
        get { value }
        set { value = newValue }
    }
}
