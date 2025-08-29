import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro {

    // Default behavior for properties inside a @Resolvable struct
    private enum ResolvableDefault {
        case optIn
        case overridable
    }

    // Generate flags parsed from `generate:` option set
    private enum ResolvablePattern {
        case full
        case nonInstantiable
    }
    
    private struct GenerateFlags {
        var hasDefinition: Bool
        var hasInstance: Bool
        // This can be simplified. If a definition exists, overrides should be included.
        var includeOverrideFields: Bool
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

         let pattern = parsePattern(from: node)

         let generateFlags: GenerateFlags
         switch pattern {
         case .full:
             generateFlags = GenerateFlags(hasDefinition: true, hasInstance: true, includeOverrideFields: true)
         case .nonInstantiable:
             generateFlags = GenerateFlags(hasDefinition: true, hasInstance: false, includeOverrideFields: true)
         }

        var allProperties: [VariableDeclSyntax] = []
        var fullOverrides: [VariableDeclSyntax] = []
        var nestedOverrides: [String: [(leafName: String, leafType: String)]] = [:]

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  binding.accessorBlock == nil
            else { continue }

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

            // Remove @Overridable / @Identity before re-emission
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

            // Decide overridability
            let isOverridable: Bool = {
                if hasIdentity { return false }
                if hasOverridable { return true }
                return (defaultBehavior == .overridable)
            }()
            guard isOverridable else { continue }

            guard let propName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  !propName.isEmpty
            else { continue }

            // Whole-property override
            guard let attr = overridableAttr,
                  let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  !args.isEmpty
            else {
                fullOverrides.append(cleanedVarDecl)
                continue
            }

            // Nested override: parse key path + leaf type
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

            guard kp.explicitRootTypeName != nil else {
                diagnoseError(context, node: Syntax(kp), id: "explicitRootRequired",
                              message: "Use an explicit root in key path (e.g. \\Shipping.carrier). Rootless paths (\\.carrier) are not allowed.")
                continue
            }

            guard let leafName = kp.lastComponentName, !leafName.isEmpty else {
                diagnoseError(context, node: Syntax(kp), id: "missingLeaf",
                              message: "Key path must include a leaf property (e.g. \\Shipping.carrier).")
                continue
            }

            let asExpr = args.first(where: { $0.label?.text == "as" })?.expression
            guard let leafTypeText = asExpr.flatMap(Self.extractTypeName(from:)), !leafTypeText.isEmpty else {
                diagnoseError(context, node: Syntax(attr), id: "missingLeafType",
                              message: "Provide leaf type with 'as: <Type>.self' (e.g. @Overridable(\\Shipping.carrier, as: String.self)).")
                continue
            }

            nestedOverrides[propName, default: []].append((leafName: leafName, leafType: leafTypeText))
        }

        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(baseName: baseName, properties: allProperties))

        if generateFlags.hasDefinition {
            decls.append(createDefinitionStruct(baseName: baseName, properties: allProperties))
            // Always generate Override if we have definitions. Fields are conditional.
            decls.append(createOverrideStruct(baseName: baseName,
                                              fullOverrides: fullOverrides,
                                              nestedOverrides: nestedOverrides,
                                              includeFields: generateFlags.includeOverrideFields))
        }
        if generateFlags.hasInstance {
            decls.append(createInstanceStruct(baseName: baseName, properties: allProperties))
        }

        if generateFlags.hasDefinition || generateFlags.hasInstance {
            decls.append(createSourceEnum(baseName: baseName,
                                          hasDefinition: generateFlags.hasDefinition,
                                          hasInstance: generateFlags.hasInstance))
            decls.append(createResolvedStruct(baseName: baseName,
                                              properties: allProperties,
                                              hasDefinition: generateFlags.hasDefinition,
                                              hasInstance: generateFlags.hasInstance))
            decls.append(createResolverStruct(baseName: baseName,
                                              allProperties: allProperties,
                                              fullOverrides: fullOverrides,
                                              nestedOverrides: nestedOverrides,
                                              hasDefinition: generateFlags.hasDefinition,
                                              hasInstance: generateFlags.hasInstance,
                                              includeOverrideFields: generateFlags.includeOverrideFields))
        }
        return decls
    }

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
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]],
                                             includeFields: Bool
    ) -> DeclSyntax {
        var fields: [String] = []

        if includeFields {
            for p in fullOverrides {
                guard let b = p.bindings.first,
                      let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let t = b.typeAnnotation?.type.trimmedDescription
                else { continue }
                fields.append("public var \(n): \(t)?")
            }
            for (parent, nested) in nestedOverrides.sorted(by: { $0.key < $1.key }) {
                for leaf in nested {
                    let varName = "\(parent)_\(leaf.leafName)"
                    fields.append("public var \(varName): \(leaf.leafType)?")
                }
            }
        }

        let fieldsBlock = fields.isEmpty ? "" : "\n            " + fields.joined(separator: "\n            ")

        // Build initializer parameters only if fields exist
        let params: [String] = fields.map { line in
            // line like: "public var title: String?" -> extract "title: String? = nil"
            let pieces = line.replacingOccurrences(of: "public var ", with: "")
            return pieces + " = nil"
        }
        let paramsBlock = params.isEmpty ? "" : ",\n                        " + params.joined(separator: ",\n                        ")

        // Assigns lines
        let assigns: [String] = fields.map { line in
            let name = line
                .replacingOccurrences(of: "public var ", with: "")
                .split(separator: ":")[0]
                .trimmingCharacters(in: .whitespaces)
            return "self.\(name) = \(name)"
        }
        let assignsBlock = assigns.isEmpty ? "" : "\n                " + assigns.joined(separator: "\n                ")

        return DeclSyntax(stringLiteral: """
        public struct Override: Identifiable, Codable, Hashable {
            public let definitionID: UUID
            public var id: UUID { definitionID }\(fieldsBlock)

            public init(definitionID: UUID\(paramsBlock)) {
                self.definitionID = definitionID\(assignsBlock)
            }
        }
        """)
    }

    private static func createSourceEnum(baseName: String,
                                         hasDefinition: Bool,
                                         hasInstance: Bool) -> DeclSyntax {
        var cases: [String] = []
        if hasDefinition { cases.append("case definition(definitionID: UUID)") }
        if hasInstance   { cases.append("case instance(instanceID: UUID)") }
        let body = cases.joined(separator: "\n            ")

        return DeclSyntax("""
        public enum Source: Hashable {
            \(raw: body)
        }
        """)
    }

    private static func createResolvedStruct(baseName: String,
                                             properties: [VariableDeclSyntax],
                                             hasDefinition: Bool,
                                             hasInstance: Bool) -> DeclSyntax {
        let props = properties.map { prop -> String in
            var m = prop
            m.bindingSpecifier = .keyword(.var, trailingTrivia: .space)
            return m.description
        }.joined(separator: "\n\n    ")

        // id computation based on available sources
        let idBody: String = {
            switch (hasDefinition, hasInstance) {
            case (true, true):
                return """
                switch source {
                case .definition(let d): return d
                case .instance(let i): return i
                }
                """
            case (true, false):
                return """
                if case let .definition(d) = source { return d }
                fatalError("Invalid source")
                """
            case (false, true):
                return """
                if case let .instance(i) = source { return i }
                fatalError("Invalid source")
                """
            default:
                // Should not be emitted (guarded by hasAnySource), but return something to satisfy compiler if reached.
                return "fatalError(\"No sources available\")"
            }
        }()

        return DeclSyntax("""
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID {
                \(raw: idBody)
            }
            public let source: Source
            \(raw: props)
        }
        """)
    }

    private static func createResolverStruct(baseName: String,
                                             allProperties: [VariableDeclSyntax],
                                             fullOverrides: [VariableDeclSyntax],
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]],
                                             hasDefinition: Bool,
                                             hasInstance: Bool,
                                             includeOverrideFields: Bool
    ) -> DeclSyntax {

        let fullSet: Set<String> = Set(fullOverrides.compactMap {
            $0.bindings.first?
                .pattern.as(IdentifierPatternSyntax.self)?
                .identifier.text
        })

        // Definition → Resolved (apply overrides only if includeOverrideFields)
        let defArgs: String = {
            guard hasDefinition else { return "" }
            return allProperties.map { p -> String in
                guard let b = p.bindings.first,
                      let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { return "" }

                if includeOverrideFields, let nested = nestedOverrides[n], !nested.isEmpty {
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
                } else if includeOverrideFields, fullSet.contains(n) {
                    return "\(n): override?.\(n) ?? def.\(n)"
                } else {
                    return "\(n): def.\(n)"
                }
            }.joined(separator: ",\n                                    ")
        }()

        // Instance → Resolved (pass-through)
        let instArgs: String = {
            guard hasInstance else { return "" }
            return allProperties.compactMap { p -> String? in
                guard let b = p.bindings.first,
                      let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { return nil }
                return "\(n): inst.\(n)"
            }.joined(separator: ",\n                             ")
        }()

        // Parameters: when definitions exist, expose a stable overrides parameter with default []
        var params: [String] = []
        if hasDefinition { params.append("definitions: [Definition]") }
        if hasDefinition { params.append("overrides: [Override] = []") }
        if hasInstance  { params.append("instances: [Instance]") }
        let paramsSig = params.joined(separator: ",\n                                       ")

        var bodyLines: [String] = []
        if hasDefinition {
            let overrideDictLine = "let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })"
            let defMap = """
            let fromDefs = definitions.map { def -> Resolved in
                let override = overrideDict[def.id]
                return Resolved(source: .definition(definitionID: def.id),
                                \(defArgs))
            }
            """
            bodyLines.append(contentsOf: [overrideDictLine, defMap])
        }
        if hasInstance {
            let instMap = """
            let fromInsts = instances.map { inst -> Resolved in
                Resolved(source: .instance(instanceID: inst.id),
                         \(instArgs))
            }
            """
            bodyLines.append(instMap)
        }
        let returnLine: String = {
            switch (hasDefinition, hasInstance) {
            case (true, true): return "return fromDefs + fromInsts"
            case (true, false): return "return fromDefs"
            case (false, true): return "return fromInsts"
            default: return "return []"
            }
        }()

        return DeclSyntax("""
        public struct Resolver {
            public static func resolve(
                                           \(raw: paramsSig)
            ) -> [Resolved] {
                \(raw: bodyLines.joined(separator: "\n            "))
                \(raw: returnLine)
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
    
    private static func parsePattern(from node: AttributeSyntax) -> ResolvablePattern {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let patternArg = args.first(where: { $0.label?.text == "pattern" })
        else {
            // If the `pattern` argument is omitted, default to `.full`.
            return .full
        }

        let text = patternArg.expression.trimmedDescription
        if text.contains("nonInstantiable") {
            return .nonInstantiable
        }

        return .full
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
