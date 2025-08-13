import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro {

    // Inject nested members: Definition, Instance, Override, Source, Resolved, Resolver
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }
        let baseName = structDecl.name.text

        var allProperties: [VariableDeclSyntax] = []
        var overridableProperties: [VariableDeclSyntax] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindings.first?.accessorBlock == nil
            else {
                continue
            }

            // AttributeListSyntax is non-optional in modern SwiftSyntax.
            let isOverridable: Bool = varDecl.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.as(IdentifierTypeSyntax.self)?
                    .name.text == "Overridable"
            }

            // Remove the @Overridable attribute from synthesized members
            var cleanedVarDecl = varDecl
            let filteredElements: [AttributeListSyntax.Element] = varDecl.attributes.compactMap { element in
                if let attr = element.as(AttributeSyntax.self),
                   let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                   name == "Overridable" {
                    return nil
                }
                return element
            }
            cleanedVarDecl.attributes = AttributeListSyntax(filteredElements)

            allProperties.append(cleanedVarDecl)
            if isOverridable {
                overridableProperties.append(cleanedVarDecl)
            }
        }

        // Generate nested types (e.g., Property.Definition, Property.Instance, etc.)
        let definitionStruct = createDefinitionStruct(baseName: baseName, properties: allProperties)
        let instanceStruct = createInstanceStruct(baseName: baseName, properties: allProperties)
        let overrideStruct = createOverrideStruct(baseName: baseName, properties: overridableProperties)
        let sourceEnum = createSourceEnum(baseName: baseName)
        let resolvedStruct = createResolvedStruct(baseName: baseName, properties: allProperties)
        let resolverStruct = createResolverStruct(baseName: baseName, allProperties: allProperties, overridableProperties: overridableProperties)
        
        let blockingInit = createBlockingUnavailableInit(baseName: baseName, properties: allProperties)
        
        // Note: We do NOT inject an init here to avoid having to initialize stored properties.
        // If you need to prevent instantiation entirely, consider the "namespace enum" pattern
        // discussed previously, or keep this struct internal.
        return [blockingInit, definitionStruct, instanceStruct, overrideStruct, sourceEnum, resolvedStruct, resolverStruct]
    }

    // Mark any user-declared initializers inside the annotated type as unavailable.
    // This does NOT affect the synthesized memberwise initializer (which only disappears
    // if any initializer is declared).
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard member.is(InitializerDeclSyntax.self) else { return [] }
        let baseName = declaration.as(StructDeclSyntax.self)?.name.text ?? "Type"
        let unavailableAttr: AttributeSyntax = """
        @available(*, unavailable, message: "Do not instantiate \(raw: baseName) directly. Use one of its nested types like .Definition or .Instance instead.")
        """
        return [unavailableAttr]
    }

    // --- Data Model Helpers ---

    private static func createBlockingUnavailableInit(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let params = properties.compactMap { prop -> String? in
            guard let binding = prop.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type.description.trimmedNonEmpty
            else { return nil }
            return "\(name): \(type)"
        }.joined(separator: ", ")

        let finalCode = """
        @available(*, unavailable, message: "Do not instantiate '\(baseName)'. Use its nested types like .Definition, .Instance, or .Resolved instead.")
        public init(\(params)) {
            fatalError("This initializer cannot be called.")
        }
        """
        return DeclSyntax(stringLiteral: finalCode)
    }
    
    private static func createDefinitionStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let propertyDecls = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        /// Auto-generated `Definition` for \(raw: baseName).
        public struct Definition: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()

            \(raw: propertyDecls)
        }
        """)
    }

    private static func createInstanceStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let propertyDecls = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        /// Auto-generated ad-hoc `Instance` for \(raw: baseName).
        public struct Instance: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()

            \(raw: propertyDecls)
        }
        """)
    }

    private static func createOverrideStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        var propertyDecls: [String] = []
        var initParams: [String] = []
        var initAssignments: [String] = []

        for property in properties {
            guard let binding = property.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type.trimmedDescription
            else {
                continue
            }
            
            propertyDecls.append("public var \(name): \(type)?")
            initParams.append("\(name): \(type)? = nil")
            initAssignments.append("self.\(name) = \(name)")
        }

        // THE FIX: The specialized convenience init has been removed.
        // We only generate the main initializer, which is always correct.
        let finalCode = """
        /// Auto-generated `Override` for \(baseName).
        public struct Override: Identifiable, Codable, Hashable {
            public let definitionID: UUID
            public var id: UUID { definitionID }

            \(propertyDecls.joined(separator: "\n    "))

            /// The main initializer, accepting an optional value for every overridable property.
            public init(
                definitionID: UUID,
                \(initParams.joined(separator: ",\n            "))
            ) {
                self.definitionID = definitionID
                \(initAssignments.joined(separator: "\n            "))
            }
        }
        """
        
        return DeclSyntax(stringLiteral: finalCode)
    }

    // --- Logic and View Model Helpers ---

    private static func createSourceEnum(baseName: String) -> DeclSyntax {
        return DeclSyntax("""
        /// Auto-generated `Source` enum for \(raw: baseName).
        public enum Source: Hashable {
            case definition(definitionID: UUID)
            case instance(instanceID: UUID)
        }
        """)
    }

    private static func createResolvedStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        // Ensure all properties in the view model are `var` for UI editing
        // which aligns with typical mutation needs in view models
        // (see: Swift's guidance on choosing let vs var) [swiftbysundell.com](https://www.swiftbysundell.com/articles/let-vs-var-for-swift-struct-properties/)
        let propertiesAsVars = properties.map { prop -> VariableDeclSyntax in
            var newProp = prop
            newProp.bindingSpecifier = .keyword(.var, trailingTrivia: .space) // avoid "varname"
            return newProp
        }

        let propertyDecls = propertiesAsVars.map { $0.description }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        /// Auto-generated `Resolved` view model for \(raw: baseName).
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID {
                switch source {
                case .definition(let definitionID):
                    return definitionID
                case .instance(let instanceID):
                    return instanceID
                }
            }

            public let source: Source
            \(raw: propertyDecls)
        }
        """)
    }

    private static func createResolverStruct(baseName: String, allProperties: [VariableDeclSyntax], overridableProperties: [VariableDeclSyntax]) -> DeclSyntax {
        let overridablePropertyNames: Set<String> = Set(
            overridableProperties.compactMap {
                $0.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            }
        )

        let definitionInitializerArgs = allProperties.map { prop -> String in
            guard let name = prop.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return "" }
            if overridablePropertyNames.contains(name) {
                return "\(name): override?.\(name) ?? definition.\(name)"
            } else {
                return "\(name): definition.\(name)"
            }
        }.joined(separator: ",\n                        ")

        let instanceInitializerArgs = allProperties.map { prop -> String in
            guard let name = prop.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return "" }
            return "\(name): instance.\(name)"
        }.joined(separator: ",\n                        ")

        return DeclSyntax("""
        /// Auto-generated `Resolver` for \(raw: baseName).
        public struct Resolver {
            public static func resolve(
                definitions: [Definition],
                overrides: [Override],
                instances: [Instance]
            ) -> [Resolved] {

                let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })

                let resolvedFromDefinitions = definitions.map { definition -> Resolved in
                    let override = overrideDict[definition.id]
                    return Resolved(
                        source: .definition(definitionID: definition.id),
                        \(raw: definitionInitializerArgs)
                    )
                }

                let resolvedFromInstances = instances.map { instance -> Resolved in
                    return Resolved(
                        source: .instance(instanceID: instance.id),
                        \(raw: instanceInitializerArgs)
                    )
                }

                return resolvedFromDefinitions + resolvedFromInstances
            }
        }
        """)
    }
}

@main
struct ResolvableMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ResolvableMacro.self,
    ]
}

extension String {
    var trimmedNonEmpty: String? {
        let s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
