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

@attached(peer)
public macro DefinitionSource(for: Any.Type? = nil, at: AnyKeyPath? = nil) = #externalMacro(
    module: "ResolvableMacros",
    type: "DefinitionSourceMacro"
)
