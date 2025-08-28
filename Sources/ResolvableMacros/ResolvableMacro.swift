import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro {

    // Default behavior for properties inside a @Resolvable struct
    private enum ResolvableDefault {
        case optIn         // Only properties marked @Overridable are overridable
        case overridable   // All properties are overridable unless marked @Identity
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }
        let baseName = structDecl.name.text

        // Parse @Resolvable(default: .overridable), default is .optIn
        var defaultBehavior: ResolvableDefault = .optIn
        if let args = node.arguments?.as(LabeledExprListSyntax.self),
           let defaultArg = args.first(where: { $0.label?.text == "default" }) {
            let text = defaultArg.expression.trimmedDescription
            if text == ".overridable" || text.hasSuffix(".overridable") || text == "\"overridable\"" {
                defaultBehavior = .overridable
            }
        }

        var allProperties: [VariableDeclSyntax] = []
        var fullOverrides: [VariableDeclSyntax] = []
        // For nested overrides: parentProp -> [(leafName, leafType)]
        var nestedOverrides: [String: [(leafName: String, leafType: String)]] = [:]

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  // Ignore computed properties
                  binding.accessorBlock == nil
            else { continue }

            // Attribute presence
            let overridableAttr = varDecl.attributes.first {
                $0.as(AttributeSyntax.self)?
                    .attributeName.as(IdentifierTypeSyntax.self)?
                    .name.text == "Overridable"
            }?.as(AttributeSyntax.self)

            let hasIdentity = varDecl.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.as(IdentifierTypeSyntax.self)?
                    .name.text == "Identity"
            }
            let hasOverridable = (overridableAttr != nil)
            let overridableHasArgs: Bool = overridableAttr?
                .arguments?
                .as(LabeledExprListSyntax.self)
                .map { !$0.isEmpty } ?? false

            // Conflict: both @Identity and @Overridable on the same property
            if hasIdentity && hasOverridable {
                context.diagnose(Diagnostic(
                    node: Syntax(varDecl),
                    message: ResolvableMessage(
                        id: "conflictingAttributes",
                        message: "Cannot apply '@Identity' and '@Overridable' to the same property.",
                        severity: .error
                    )
                ))
            }

            // Redundancy warnings:
            // - When default is .overridable, a no-arg @Overridable is redundant.
            if defaultBehavior == .overridable, hasOverridable, !overridableHasArgs {
                context.diagnose(Diagnostic(
                    node: Syntax(overridableAttr!),
                    message: ResolvableMessage(
                        id: "redundantOverridable",
                        message: "'@Overridable' is redundant when using '@Resolvable(default: .overridable)' unless you are specifying nested key-path overrides.",
                        severity: .warning
                    )
                ))
            }
            // - When default is .optIn, @Identity is redundant (everything is non-overridable by default).
            if defaultBehavior == .optIn, hasIdentity, !hasOverridable {
                context.diagnose(Diagnostic(
                    node: Syntax(varDecl),
                    message: ResolvableMessage(
                        id: "redundantIdentity",
                        message: "'@Identity' is redundant with '@Resolvable' default behavior (opt-in). Properties are non-overridable unless marked '@Overridable'.",
                        severity: .warning
                    )
                ))
            }

            // Clean attributes (remove @Overridable and @Identity) for re-emission
            var cleanedVarDecl = varDecl
            let filtered = varDecl.attributes.compactMap { elem -> AttributeListSyntax.Element? in
                if let attr = elem.as(AttributeSyntax.self),
                   let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                   name == "Overridable" || name == "Identity" {
                    return nil
                }
                return elem
            }
            cleanedVarDecl.attributes = AttributeListSyntax(filtered)
            allProperties.append(cleanedVarDecl)

            // Decide overridability with default behavior + annotations
            let isOverridable: Bool = {
                if hasIdentity { return false }
                if hasOverridable { return true }
                return (defaultBehavior == .overridable)
            }()

            guard isOverridable else { continue }

            // Property name (skip odd patterns just in case)
            guard let propName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  !propName.isEmpty
            else { continue }

            // If attribute not present or has no args → whole-property override
            guard let attr = overridableAttr,
                  let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  !args.isEmpty
            else {
                // Whole property override
                fullOverrides.append(cleanedVarDecl)
                continue
            }

            // Nested override path and leaf type parsing

            // Key path: unlabeled first argument, or labeled keyPath:
            let keyPathExpr: KeyPathExprSyntax? = {
                if let labeled = args.first(where: { $0.label?.text == "keyPath" })?.expression.as(KeyPathExprSyntax.self) {
                    return labeled
                }
                if let first = args.first, first.label == nil,
                   let kp = first.expression.as(KeyPathExprSyntax.self) {
                    return kp
                }
                return nil
            }()

            guard let kp = keyPathExpr else {
                diagnoseError(context, node: Syntax(attr), id: "missingKeyPath",
                              message: "@Overridable requires a key-path (e.g. @Overridable(\\Shipping.carrier, as: String.self))")
                continue
            }

            // Require explicit root (\Shipping.carrier), not rootless (\.carrier)
            guard kp.explicitRootTypeName != nil else {
                diagnoseError(context, node: Syntax(kp), id: "explicitRootRequired",
                              message: "Use an explicit root in key path (e.g. \\Shipping.carrier). Rootless paths (\\.carrier) are not allowed.")
                continue
            }

            // Leaf name (e.g., "carrier")
            guard let leafName = kp.lastComponentName, !leafName.isEmpty else {
                diagnoseError(context, node: Syntax(kp), id: "missingLeaf",
                              message: "Key path must include a leaf property (e.g. \\Shipping.carrier).")
                continue
            }

            // Leaf type via as: Type.self
            let asExpr = args.first(where: { $0.label?.text == "as" })?.expression
            guard let leafTypeText = asExpr.flatMap(Self.extractTypeName(from:)), !leafTypeText.isEmpty else {
                diagnoseError(context, node: Syntax(attr), id: "missingLeafType",
                              message: "Provide leaf type with 'as: <Type>.self' (e.g. @Overridable(\\Shipping.carrier, as: String.self)).")
                continue
            }

            // Record nested override
            nestedOverrides[propName, default: []].append((leafName: leafName, leafType: leafTypeText))
        }

        return [
            createBlockingUnavailableInit(baseName: baseName, properties: allProperties),
            createDefinitionStruct(baseName: baseName, properties: allProperties),
            createInstanceStruct(baseName: baseName, properties: allProperties),
            createOverrideStruct(baseName: baseName,
                                 fullOverrides: fullOverrides,
                                 nestedOverrides: nestedOverrides),
            createSourceEnum(baseName: baseName),
            createResolvedStruct(baseName: baseName, properties: allProperties),
            createResolverStruct(baseName: baseName,
                                 allProperties: allProperties,
                                 fullOverrides: fullOverrides,
                                 nestedOverrides: nestedOverrides)
        ]
    }

    // Mark user-defined inits in the base type as unavailable (discourage direct instantiation)
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard member.is(InitializerDeclSyntax.self) else { return [] }
        let baseName = declaration.as(StructDeclSyntax.self)?.name.text ?? "Type"
        let attr: AttributeSyntax = """
        @available(*, unavailable,
                   message: "Do not instantiate \(raw: baseName) directly. Use nested types like .Definition or .Instance instead.")
        """
        return [attr]
    }

    // MARK: - Generated types

    private static func createBlockingUnavailableInit(baseName: String,
                                                      properties: [VariableDeclSyntax]) -> DeclSyntax {
        let params = properties.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let t = b.typeAnnotation?.type.description.trimmedNonEmpty
            else { return nil }
            return "\(n): \(t)"
        }.joined(separator: ", ")

        return DeclSyntax(stringLiteral: """
        @available(*, unavailable,
                   message: "Do not instantiate '\(baseName)'. Use nested types instead.")
        public init(\(params)) { fatalError("This initializer cannot be called.") }
        """)
    }

    private static func createDefinitionStruct(baseName: String,
                                               properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        public struct Definition: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """)
    }

    private static func createInstanceStruct(baseName: String,
                                             properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        public struct Instance: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """)
    }

    private static func createOverrideStruct(baseName: String,
                                             fullOverrides: [VariableDeclSyntax],
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]]
    ) -> DeclSyntax {
        var fields: [String] = []
        var params: [String] = []
        var assigns: [String] = []

        // Whole-property overrides
        for p in fullOverrides {
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let t = b.typeAnnotation?.type.trimmedDescription
            else { continue }
            fields.append("public var \(n): \(t)?")
            params.append("\(n): \(t)? = nil")
            assigns.append("self.\(n) = \(n)")
        }

        // Nested overrides → parent_leaf
        for (parent, nested) in nestedOverrides.sorted(by: { $0.key < $1.key }) {
            for leaf in nested {
                let varName = "\(parent)_\(leaf.leafName)"
                fields.append("public var \(varName): \(leaf.leafType)?")
                params.append("\(varName): \(leaf.leafType)? = nil")
                assigns.append("self.\(varName) = \(varName)")
            }
        }

        let fieldsBlock = fields.isEmpty ? "" : fields.joined(separator: "\n    ")
        let paramsBlock = params.isEmpty ? "" : ",\n                        " + params.joined(separator: ",\n                        ")
        let assignsBlock = assigns.joined(separator: "\n                ")

        return DeclSyntax(stringLiteral: """
        public struct Override: Identifiable, Codable, Hashable {
            public let definitionID: UUID
            public var id: UUID { definitionID }

            \(fieldsBlock)

            public init(definitionID: UUID\(paramsBlock)) {
                self.definitionID = definitionID
                \(assignsBlock)
            }
        }
        """)
    }

    private static func createSourceEnum(baseName: String) -> DeclSyntax {
        DeclSyntax("""
        public enum Source: Hashable {
            case definition(definitionID: UUID)
            case instance(instanceID: UUID)
        }
        """)
    }

    private static func createResolvedStruct(baseName: String,
                                             properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { prop -> String in
            var m = prop
            m.bindingSpecifier = .keyword(.var, trailingTrivia: .space)
            return m.description
        }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID {
                switch source {
                case .definition(let d): return d
                case .instance(let i): return i
                }
            }
            public let source: Source
            \(raw: props)
        }
        """)
    }

    private static func createResolverStruct(baseName: String,
                                             allProperties: [VariableDeclSyntax],
                                             fullOverrides: [VariableDeclSyntax],
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]]
    ) -> DeclSyntax {
        let fullSet: Set<String> = Set(fullOverrides.compactMap {
            $0.bindings.first?
                .pattern.as(IdentifierPatternSyntax.self)?
                .identifier.text
        })

        // From Definition → Resolved (apply overrides)
        let defArgs = allProperties.map { p -> String in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { return "" }

            if let nested = nestedOverrides[n], !nested.isEmpty {
                let mutations = nested.map { leaf in
                    "if let v = override?.\(n)_\(leaf.leafName) { value.\(leaf.leafName) = v }"
                }.joined(separator: "\n                                        ")
                return """
                \(n): {
                                        var value = def.\(n)
                                        \(mutations)
                                        return value
                                    }()
                """
            } else if fullSet.contains(n) {
                return "\(n): override?.\(n) ?? def.\(n)"
            } else {
                return "\(n): def.\(n)"
            }
        }.joined(separator: ",\n                                    ")

        // From Instance → Resolved (pass-through)
        let instArgs = allProperties.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { return nil }
            return "\(n): inst.\(n)"
        }.joined(separator: ",\n                             ")

        return DeclSyntax("""
        public struct Resolver {
            public static func resolve(definitions: [Definition],
                                       overrides: [Override],
                                       instances: [Instance]) -> [Resolved] {
                let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })
                let fromDefs = definitions.map { def -> Resolved in
                    let override = overrideDict[def.id]
                    return Resolved(source: .definition(definitionID: def.id),
                                    \(raw: defArgs))
                }
                let fromInsts = instances.map { inst -> Resolved in
                    Resolved(source: .instance(instanceID: inst.id),
                             \(raw: instArgs))
                }
                return fromDefs + fromInsts
            }
        }
        """)
    }

    // Extract "String" from "String.self"
    private static func extractTypeName(from expr: ExprSyntax) -> String? {
        let text = expr.trimmedDescription
        if text.hasSuffix(".self") {
            return String(text.dropLast(5))
        }
        return text
    }
}

// Diagnostics

private func diagnoseError(_ context: some MacroExpansionContext,
                           node: Syntax,
                           id: String,
                           message: String) {
    context.diagnose(Diagnostic(node: node, message: ResolvableMessage(id: id, message: message, severity: .error)))
}

private struct ResolvableMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(domain: String = "Resolvable", id: String, message: String, severity: DiagnosticSeverity) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id)
        self.severity = severity
    }
}

@main
struct ResolvableMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ResolvableMacro.self]
}

// Helpers

extension String {
    var trimmedNonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

extension SyntaxProtocol {
    var trimmedDescription: String {
        self.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// KeyPath helpers (explicit root, leaf component)
extension KeyPathExprSyntax {
    var explicitRootTypeName: String? {
        self.root?.as(IdentifierTypeSyntax.self)?.name.text
    }
    var lastComponentName: String? {
        self.components.last?
            .component.as(KeyPathPropertyComponentSyntax.self)?
            .declName.baseName.text
    }
}
