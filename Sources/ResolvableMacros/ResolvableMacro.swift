import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro {

    // --- NEW: Simplified API Enums and Structs ---
    public enum ResolvablePattern {
        case full
        case nonInstantiable
    }

    private enum ResolvableDefault {
        case identity
        case overridable
    }

    private struct GenerateFlags {
        var hasDefinition: Bool
        var hasInstance: Bool
        var includeOverrideFields: Bool
    }

    // MARK: - Main Expansion
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }
        let baseName = structDecl.name.text

        // --- UPDATED LOGIC ---
        // 1. Parse the new `pattern:` argument.
        let pattern = parsePattern(from: node)
        
        // 2. Set up GenerateFlags based on the simple pattern.
        let generateFlags: GenerateFlags
        switch pattern {
        case .full:
            generateFlags = GenerateFlags(hasDefinition: true, hasInstance: true, includeOverrideFields: true)
        case .nonInstantiable:
            generateFlags = GenerateFlags(hasDefinition: true, hasInstance: false, includeOverrideFields: true)
        }

        // 3. Parse the `default:` argument (this logic remains).
        var defaultBehavior: ResolvableDefault = .identity
        if let args = node.arguments?.as(LabeledExprListSyntax.self),
           let defaultArg = args.first(where: { $0.label?.text == "default" }) {
            let text = defaultArg.expression.trimmedDescription
            if text.contains("overridable") {
                defaultBehavior = .overridable
            }
        }
        // --- END OF UPDATED LOGIC ---

        var allProperties: [VariableDeclSyntax] = []
        var fullOverrides: [VariableDeclSyntax] = []
        var nestedOverrides: [String: [(leafName: String, leafType: String)]] = [:]

        // ... (The entire `for member in structDecl.memberBlock.members` loop remains exactly the same) ...
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
            
            // ... (rest of the loop is unchanged) ...
            
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
            
            // ... (rest of the property parsing logic is unchanged) ...
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
            
            // ... (nested override parsing logic is unchanged) ...
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

            guard let kp = keyPathExpr else { continue }
            guard let leafName = kp.lastComponentName, !leafName.isEmpty else { continue }
            let asExpr = args.first(where: { $0.label?.text == "as" })?.expression
            guard let leafTypeText = asExpr.flatMap(Self.extractTypeName(from:)), !leafTypeText.isEmpty else { continue }
            nestedOverrides[propName, default: []].append((leafName: leafName, leafType: leafTypeText))
        }

        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(baseName: baseName, properties: allProperties))

        if generateFlags.hasDefinition {
            decls.append(createDefinitionStruct(baseName: baseName, properties: allProperties))
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
        @available(*, unavailable, message: "Do not instantiate \(raw: baseName) directly. Use nested types like .Definition or .Instance instead.")
        """
        return [attr]
    }

    // MARK: - Generated types
    // ... (All `create...` functions are UNCHANGED except for the new `createResolverStruct`) ...
    private static func createBlockingUnavailableInit(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
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

    private static func createDefinitionStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        public struct Definition: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """)
    }

    private static func createInstanceStruct(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        public struct Instance: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """)
    }

    private static func createOverrideStruct(baseName: String, fullOverrides: [VariableDeclSyntax], nestedOverrides: [String: [(leafName: String, leafType: String)]], includeFields: Bool) -> DeclSyntax {
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
        let params: [String] = fields.map { line in
            let pieces = line.replacingOccurrences(of: "public var ", with: "")
            return pieces + " = nil"
        }
        let paramsBlock = params.isEmpty ? "" : ",\n                        " + params.joined(separator: ",\n                        ")
        let assigns: [String] = fields.map { line in
            let name = line.replacingOccurrences(of: "public var ", with: "").split(separator: ":")[0].trimmingCharacters(in: .whitespaces)
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
    
    private static func createSourceEnum(baseName: String, hasDefinition: Bool, hasInstance: Bool) -> DeclSyntax {
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
    
    private static func createResolvedStruct(baseName: String, properties: [VariableDeclSyntax], hasDefinition: Bool, hasInstance: Bool) -> DeclSyntax {
        let props = properties.map { prop -> String in
            var m = prop
            m.bindingSpecifier = .keyword(.var, trailingTrivia: .space)
            return m.description
        }.joined(separator: "\n\n    ")
        let idBody: String = {
            switch (hasDefinition, hasInstance) {
            case (true, true): return "switch source { case .definition(let d): return d; case .instance(let i): return i }"
            case (true, false): return "if case let .definition(d) = source { return d }; fatalError(\"Invalid source\")"
            case (false, true): return "if case let .instance(i) = source { return i }; fatalError(\"Invalid source\")"
            default: return "fatalError(\"No sources available\")"
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

    // --- THIS IS THE UPDATED RESOLVER FUNCTION ---
    private static func createResolverStruct(baseName: String,
                                             allProperties: [VariableDeclSyntax],
                                             fullOverrides: [VariableDeclSyntax],
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]],
                                             hasDefinition: Bool,
                                             hasInstance: Bool,
                                             includeOverrideFields: Bool
    ) -> DeclSyntax {
        
        var singleResolverDef: String = ""
        var batchResolverDef: String = ""
        var instanceResolver: String = ""
        
        if hasDefinition {
            let fullOverrideSet = Set(fullOverrides.compactMap { $0.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text })
            
            let resolvedInitArgs = allProperties.map { p -> String in
                guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return "" }
                
                if includeOverrideFields, fullOverrideSet.contains(n) {
                    return "\(n): override?.\(n) ?? definition.\(n)"
                } else {
                    return "\(n): definition.\(n)"
                }
            }.joined(separator: ",\n            ")

            singleResolverDef = """
            public static func resolve(definition: Definition, override: Override?) -> Resolved {
                return Resolved(
                    source: .definition(definitionID: definition.id),
                    \(resolvedInitArgs)
                )
            }
            """
            
            batchResolverDef = """
            public static func resolve(definitions: [Definition], overrides: [Override] = []) -> [Resolved] {
                let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })
                return definitions.map { def in
                    let override = overrideDict[def.id]
                    return resolve(definition: def, override: override)
                }
            }
            """
        }
        
        if hasInstance {
            let instArgs = allProperties.compactMap { p -> String? in
                guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return nil }
                return "\(n): inst.\(n)"
            }.joined(separator: ",\n                         ")
            
            instanceResolver = """
            public static func resolve(instances: [Instance]) -> [Resolved] {
                return instances.map { inst in
                    Resolved(source: .instance(instanceID: inst.id),
                             \(instArgs))
                }
            }
            """
        }

        return DeclSyntax("""
        public struct Resolver {
            \(raw: singleResolverDef)
            \(raw: batchResolverDef)
            \(raw: instanceResolver)
        }
        """)
    }

    // --- NEW HELPER FUNCTION ---
    private static func parsePattern(from node: AttributeSyntax) -> ResolvablePattern {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let patternArg = args.first(where: { $0.label?.text == "pattern" })
        else {
            return .full
        }
        let text = patternArg.expression.trimmedDescription
        if text.contains("nonInstantiable") {
            return .nonInstantiable
        }
        return .full
    }

    // ... (rest of the helper functions: extractTypeName, diagnoseError, etc. are unchanged) ...
    private static func extractTypeName(from expr: ExprSyntax) -> String? {
        let text = expr.trimmedDescription
        if text.hasSuffix(".self") { return String(text.dropLast(5)) }
        return text
    }

    private static func diagnoseError(_ context: some MacroExpansionContext, node: Syntax, id: String, message: String) {
        context.diagnose(Diagnostic(node: node, message: ResolvableMessage(id: id, message: message, severity: .error)))
    }
}

// ... (ResolvableMessage, Plugin, and Extensions are unchanged) ...
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

extension KeyPathExprSyntax {
    var explicitRootTypeName: String? {
        self.root?.as(IdentifierTypeSyntax.self)?.name.text
    }
    var lastComponentName: String? {
        self.components.last?.component.as(KeyPathPropertyComponentSyntax.self)?.declName.baseName.text
    }
}
