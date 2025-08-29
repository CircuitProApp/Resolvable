// Sources/Storable/Storable.swift
import Foundation

/// The `@Storable` macro generates:
/// - Definition: SwiftData-ready @Model with explicit initializer
/// - Instance: @Observable (when available) + Codable, with its own id and a reference `definitionID`
/// - Resolved: read-only, UI-ready view that prefers instance values
/// - Resolver: helpers to build Resolved from pairs/batches
@attached(
    member,
    names:
        named(Definition),
        named(Instance),
        named(Resolved),
        named(Resolver),
        named(Source),
        named(init)
)
@attached(memberAttribute)
public macro Storable() = #externalMacro(module: "StorableMacros", type: "StorableMacro")
