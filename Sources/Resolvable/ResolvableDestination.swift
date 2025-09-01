//
//  ResolvableDestination.swift
//  Resolvable
//
//  Created by Giorgi Tchelidze on 9/1/25.
//

import Foundation

// Attach both member- and extension-roles.
@attached(
    member,
    names:
        // Members we might emit
        named(ResolvableType),
        named(definitions),
        named(overrides),
        named(instances),
        named(markAsChanged)
)
@attached(extension, conformances: ResolvableBacked)
public macro ResolvableDestination(for resolvable: Any.Type) = #externalMacro(
    module: "ResolvableMacros",
    type: "ResolvableDestinationMacro"
)

@propertyWrapper
public struct DefinitionSource<Value> {
    public let resolvableType: Any.Type?
    public let keyPath: AnyKeyPath?

    // Compile-time only
    public var wrappedValue: Value {
        get { fatalError("DefinitionSource is compile-time only") }
        set { fatalError("DefinitionSource is compile-time only") }
    }

    // 1) Marker only: @DefinitionSource
    public init() {
        self.resolvableType = nil
        self.keyPath = nil
    }

    // 2) Target only: @DefinitionSource(for: Model.self)
    public init(for resolvable: Any.Type) {
        self.resolvableType = resolvable
        self.keyPath = nil
    }

    // 3) Path only: @DefinitionSource(at: \Container.definitions)
    public init(at keyPath: AnyKeyPath) {
        self.resolvableType = nil
        self.keyPath = keyPath
    }

    // 4) Target + Path: @DefinitionSource(for: Model.self, at: \Container.definitions)
    public init(for resolvable: Any.Type, at keyPath: AnyKeyPath) {
        self.resolvableType = resolvable
        self.keyPath = keyPath
    }

    // 5) wrappedValue variants (compile-time only)
    public init(wrappedValue: Value) {
        self.resolvableType = nil
        self.keyPath = nil
    }

    public init(wrappedValue: Value, for resolvable: Any.Type) {
        self.resolvableType = resolvable
        self.keyPath = nil
    }

    public init(wrappedValue: Value, at keyPath: AnyKeyPath) {
        self.resolvableType = nil
        self.keyPath = keyPath
    }

    public init(wrappedValue: Value, for resolvable: Any.Type, at keyPath: AnyKeyPath) {
        self.resolvableType = resolvable
        self.keyPath = keyPath
    }
}
