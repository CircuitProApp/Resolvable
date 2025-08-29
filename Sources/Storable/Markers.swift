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
    public enum Source { case storable, resolvable }

    // Use this when no initial value is provided (e.g., `@StorableRelationship(...) var rel: T`)
    public init(
        source: Source = .storable,
        deleteRule: Schema.Relationship.DeleteRule? = nil,
        inverse: AnyKeyPath? = nil
    ) {}

    // Overload to allow `= initialValue` if ever used
    public init(
        wrappedValue: Value,
        source: Source = .storable,
        deleteRule: Schema.Relationship.DeleteRule? = nil,
        inverse: AnyKeyPath? = nil
    ) {}

    public var wrappedValue: Value {
        get { fatalError("StorableRelationship is a marker used by @Storable; not for runtime use.") }
        set {}
    }
}
