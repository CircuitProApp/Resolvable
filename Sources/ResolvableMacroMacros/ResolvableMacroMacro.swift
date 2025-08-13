import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ResolvableMacro: PeerMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
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

            // AttributeListSyntax is non-optional in your toolchain.
            let isOverridable: Bool = varDecl.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.as(IdentifierTypeSyntax.self)?
                    .name.text == "Overridable"
            }

            // Remove the @Overridable attribute from the synthesized structs
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

        let definitionStruct = createDefinitionStruct(baseName: baseName, properties: allProperties)
        let instanceStruct = createInstanceStruct(baseName: baseName, properties: allProperties)
        let overrideStruct = createOverrideStruct(baseName: baseName, properties: overridableProperties)
        let sourceEnum = createSourceEnum(baseName: baseName)
        let resolvedStruct = createResolvedStruct(baseName: baseName, properties: allProperties)
        let resolverStruct = createResolverStruct(baseName: baseName, allProperties: allProperties, overridableProperties: overridableProperties)

        return [definitionStruct, instanceStruct, overrideStruct, sourceEnum, resolvedStruct, resolverStruct]
    }

    // --- Data Model Helpers ---

    private static func createDefinitionStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let propertyDecls = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        /// Auto-generated `Definition` for \(raw: baseName).
        public struct \(raw: baseName)Definition: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()

            \(raw: propertyDecls)
        }
        """)
    }

    private static func createInstanceStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let propertyDecls = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        /// Auto-generated ad-hoc `Instance` for \(raw: baseName).
        public struct \(raw: baseName)Instance: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()

            \(raw: propertyDecls)
        }
        """)
    }

    private static func createOverrideStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let overrideProperties = properties.map { property -> VariableDeclSyntax in
            var newProperty = property
            guard var newBinding = newProperty.bindings.first,
                  let typeAnnotation = newBinding.typeAnnotation else {
                return newProperty
            }

            let optionalType = OptionalTypeSyntax(wrappedType: typeAnnotation.type)
            newBinding.typeAnnotation = TypeAnnotationSyntax(type: TypeSyntax(optionalType))
            newBinding.initializer = InitializerClauseSyntax(value: ExprSyntax(NilLiteralExprSyntax()))
            newProperty.bindingSpecifier = .keyword(.var, trailingTrivia: .space)
            newProperty.bindings = PatternBindingListSyntax([newBinding])
            return newProperty
        }

        let propertyDecls = overrideProperties.map { $0.description }.joined(separator: "\n    ")
        return DeclSyntax("""
        /// Auto-generated `Override` for \(raw: baseName).
        public struct \(raw: baseName)Override: Identifiable, Codable, Hashable {
            public let definitionID: UUID
            public var id: UUID { definitionID }

            \(raw: propertyDecls)
        }
        """)
    }

    // --- Logic and View Model Helpers ---

    private static func createSourceEnum(baseName: String) -> DeclSyntax {
        return DeclSyntax("""
        /// Auto-generated `Source` enum for \(raw: baseName).
        public enum \(raw: baseName)Source: Hashable {
            case definition(definitionID: UUID)
            case instance(instanceID: UUID)
        }
        """)
    }

    private static func createResolvedStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let propertiesAsVars = properties.map { prop -> VariableDeclSyntax in
            var newProp = prop
            newProp.bindingSpecifier = .keyword(.var, trailingTrivia: .space)
            return newProp
        }

        let propertyDecls = propertiesAsVars.map { $0.description }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        /// Auto-generated `Resolved` view model for \(raw: baseName).
        public struct \(raw: baseName)Resolved: Identifiable, Hashable {
            public var id: UUID {
                switch source {
                case .definition(let definitionID):
                    return definitionID
                case .instance(let instanceID):
                    return instanceID
                }
            }

            public let source: \(raw: baseName)Source
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
        public struct \(raw: baseName)Resolver {
            public static func resolve(
                definitions: [\(raw: baseName)Definition],
                overrides: [\(raw: baseName)Override],
                instances: [\(raw: baseName)Instance]
            ) -> [\(raw: baseName)Resolved] {

                let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })

                let resolvedFromDefinitions = definitions.map { definition -> \(raw: baseName)Resolved in
                    let override = overrideDict[definition.id]
                    return \(raw: baseName)Resolved(
                        source: .definition(definitionID: definition.id),
                        \(raw: definitionInitializerArgs)
                    )
                }

                let resolvedFromInstances = instances.map { instance -> \(raw: baseName)Resolved in
                    return \(raw: baseName)Resolved(
                        source: .instance(instanceID: instance.id),
                        \(raw: instanceInitializerArgs)
                    )
                }

                return resolvedFromDefinitions + resolvedFromInstances
            }
        }
        """)
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {

        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
        let baseName = structDecl.name.text

        // Qualify peer types with the containing scope (e.g., "TestModels.") if present
        let typeDesc = type.trimmed.description
        let qualifier: String
        if let dot = typeDesc.lastIndex(of: ".") {
            qualifier = String(typeDesc[..<dot]) + "."
        } else {
            qualifier = ""
        }

        let ext = try ExtensionDeclSyntax("""
        extension \(type.trimmed) {
            public typealias Definition = \(raw: qualifier)\(raw: baseName)Definition
            public typealias Instance   = \(raw: qualifier)\(raw: baseName)Instance
            public typealias Override   = \(raw: qualifier)\(raw: baseName)Override
            public typealias Resolved   = \(raw: qualifier)\(raw: baseName)Resolved
            public typealias Source     = \(raw: qualifier)\(raw: baseName)Source
            public typealias Resolver   = \(raw: qualifier)\(raw: baseName)Resolver
        }
        """)

        return [ext]
    }
}

@main
struct ResolvableMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ResolvableMacro.self,
    ]
}
