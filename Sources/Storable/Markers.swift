//
//  Markers.swift
//  Resolvable
//
//  Created by Giorgi Tchelidze on 8/29/25.
//

import SwiftData

@propertyWrapper
public struct DefinitionStored<Value> {
    public init() {}
    public init(wrappedValue: Value) {}
    public var wrappedValue: Value {
        get { fatalError("DefinitionStored is a marker used by @Storable; not for runtime use.") }
        set {}
    }
}

@propertyWrapper
public struct InstanceStored<Value> {
    public init() {}
    public init(wrappedValue: Value) {}
    public var wrappedValue: Value {
        get { fatalError("InstanceStored is a marker used by @Storable; not for runtime use.") }
        set {}
    }
}

@propertyWrapper
public struct StorableRelationship<Value> {

    public init(
        deleteRule: Schema.Relationship.DeleteRule? = nil,
        inverse: AnyKeyPath? = nil
    ) {}

    public init(
        wrappedValue: Value,
        deleteRule: Schema.Relationship.DeleteRule? = nil,
        inverse: AnyKeyPath? = nil
    ) {}

    public var wrappedValue: Value {
        get { fatalError("StorableRelationship is a marker used by @Storable; not for runtime use.") }
        set {}
    }
}

@propertyWrapper
public struct ResolvableProperty<Value> {
    /// Configures the macro to generate storage for a nested resolvable property.
    /// The types passed here are markers only; their values are not used at runtime.
    /// The macro inspects the code you write to determine what to generate.
    ///
    //  Example:
    //  @ResolvableProperty(
    //      definition: CircuitText.Definition.self,
    //      instance: [CircuitText.Override.self, CircuitText.Instance.self]
    //  )
    public init(
        definition: Any.Type,
        instance: [Any.Type]
    ) {
        // This initializer is empty. Its only purpose is to provide a valid
        // syntactic structure for the developer to write the command.
    }
    
    public init(
        wrappedValue: Value,
        definition: Any.Type,
        instance: [Any.Type]
    ) {
        // Also empty.
    }
    
    public var wrappedValue: Value {
        get { fatalError("This is a marker attribute for the @Storable macro and should not be accessed at runtime.") }
        set {}
    }
}
