import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro {
    
    // MARK: - API Configuration Enums
    public enum ResolvablePattern {
        case full
        case nonInstantiable
    }
    
    private enum ResolvableDefault {
        case identity
        case overridable
    }
    
    // MARK: - Internal State
    private struct GenerateFlags {
        var hasDefinition: Bool
        var hasInstance: Bool
        // This can be simplified. If a definition exists, overrides should be included.
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
        
        let pattern = parsePattern(from: node)
        
        let generateFlags: GenerateFlags
        switch pattern {
        case .full:
            generateFlags = GenerateFlags(hasDefinition: true, hasInstance: true, includeOverrideFields: true)
        case .nonInstantiable:
            generateFlags = GenerateFlags(hasDefinition: true, hasInstance: false, includeOverrideFields: true)
        }
        
        var defaultBehavior: ResolvableDefault = .identity
        if let args = node.arguments?.as(LabeledExprListSyntax.self),
           let defaultArg = args.first(where: { $0.label?.text == "default" }) {
            let text = defaultArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("overridable") { defaultBehavior = .overridable }
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
                $0.as(AttributeSyntax.self)?.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Overridable"
            }?.as(AttributeSyntax.self)
            
            let hasIdentity = varDecl.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Identity"
            }
            let hasOverridable = (overridableAttr != nil)
            
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
            
            let isOverridable = (hasOverridable || defaultBehavior == .overridable) && !hasIdentity
            guard isOverridable else { continue }
            
            guard let propName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text, !propName.isEmpty else { continue }
            
            guard let attr = overridableAttr, let args = attr.arguments?.as(LabeledExprListSyntax.self), !args.isEmpty else {
                fullOverrides.append(cleanedVarDecl)
                continue
            }
            
            let keyPathExpr = args.lazy.compactMap { $0.expression.as(KeyPathExprSyntax.self) }.first
            guard let kp = keyPathExpr else { continue }
            guard let leafName = kp.lastComponentName, !leafName.isEmpty else { continue }
            let asExpr = args.first(where: { $0.label?.text == "as" })?.expression
            guard let leafTypeText = asExpr.flatMap(Self.extractTypeName(from:)), !leafTypeText.isEmpty else { continue }
            nestedOverrides[propName, default: []].append((leafName: leafName, leafType: leafTypeText))
        }
        
        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(baseName: baseName, properties: allProperties))
        
        if generateFlags.hasDefinition {
            decls.append(createDefinitionStruct(properties: allProperties))
            decls.append(createOverrideStruct(fullOverrides: fullOverrides,
                                              nestedOverrides: nestedOverrides,
                                              includeFields: generateFlags.includeOverrideFields))
        }
        if generateFlags.hasInstance {
            decls.append(createInstanceStruct(properties: allProperties))
        }
        
        if generateFlags.hasDefinition || generateFlags.hasInstance {
            decls.append(createSourceEnum(hasDefinition: generateFlags.hasDefinition, hasInstance: generateFlags.hasInstance))
            decls.append(createResolvedStruct(properties: allProperties,
                                              hasDefinition: generateFlags.hasDefinition,
                                              hasInstance: generateFlags.hasInstance))
            decls.append(createResolverStruct(allProperties: allProperties,
                                              fullOverrides: fullOverrides,
                                              nestedOverrides: nestedOverrides,
                                              hasDefinition: generateFlags.hasDefinition,
                                              hasInstance: generateFlags.hasInstance))
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
        let attr: AttributeSyntax = "@available(*, unavailable, message: \"Do not instantiate \(raw: baseName) directly. Use nested types instead.\")"
        return [attr]
    }
    
    // MARK: - Generation
    private static func createBlockingUnavailableInit(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let params = properties.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let t = b.typeAnnotation?.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            return "\(n): \(t)"
        }.joined(separator: ", ")
        
        return """
        @available(*, unavailable, message: "Do not instantiate '\(raw: baseName)'. Use nested types instead.")
        public init(\(raw: params)) { fatalError("This initializer cannot be called.") }
        """
    }
    
    private static func createDefinitionStruct(properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return """
        public struct Definition: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """
    }
    
    private static func createInstanceStruct(properties: [VariableDeclSyntax]) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        return """
        public struct Instance: Identifiable, Codable, Hashable {
            public var id: UUID = UUID()
            \(raw: props)
        }
        """
    }
    
    private static func createOverrideStruct(fullOverrides: [VariableDeclSyntax], nestedOverrides: [String: [(leafName: String, leafType: String)]], includeFields: Bool) -> DeclSyntax {
        var fields: [String] = []
        if includeFields {
            for p in fullOverrides {
                guard let b = p.bindings.first,
                      let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let t = b.typeAnnotation?.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                else { continue }
                fields.append("public var \(n): \(t)?")
            }
            for (parent, nested) in nestedOverrides.sorted(by: { $0.key < $1.key }) {
                for leaf in nested {
                    fields.append("public var \(parent)_\(leaf.leafName): \(leaf.leafType)?")
                }
            }
        }
        let fieldsBlock = fields.isEmpty ? "" : "\n    " + fields.joined(separator: "\n    ")
        let params = fields.map { line in
            (line.replacingOccurrences(of: "public var ", with: "")) + " = nil"
        }
        let paramsBlock = params.isEmpty ? "" : ",\n        " + params.joined(separator: ",\n        ")
        let assigns = fields.map { line in
            let name = line.replacingOccurrences(of: "public var ", with: "").split(separator: ":")[0].trimmingCharacters(in: .whitespaces)
            return "self.\(name) = \(name)"
        }
        let assignsBlock = assigns.isEmpty ? "" : "\n        " + assigns.joined(separator: "\n        ")
        return """
        public struct Override: Identifiable, Codable, Hashable {
            public let definitionID: UUID
            public var id: UUID { definitionID }\(raw: fieldsBlock)
            public init(definitionID: UUID\(raw: paramsBlock)) {
                self.definitionID = definitionID\(raw: assignsBlock)
            }
        }
        """
    }
    
    private static func createSourceEnum(hasDefinition: Bool, hasInstance: Bool) -> DeclSyntax {
        var cases: [String] = []
        if hasDefinition { cases.append("case definition(definition: Definition)") }
        if hasInstance { cases.append("case instance(instance: Instance)") }
        return """
        public enum Source: Hashable {
            \(raw: cases.joined(separator: "\n    "))
        }
        """
    }
    
    private static func createResolvedStruct(properties: [VariableDeclSyntax], hasDefinition: Bool, hasInstance: Bool) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        let idBody: String = {
            switch (hasDefinition, hasInstance) {
            case (true, true): return "switch source { case .definition(let d): return d.id; case .instance(let i): return i.id }"
            case (true, false): return "if case let .definition(d) = source { return d.id }; fatalError(\"Invalid source\")"
            case (false, true): return "if case let .instance(i) = source { return i.id }; fatalError(\"Invalid source\")"
            default: return "fatalError(\"No sources available\")"
            }
        }()
        return """
        public struct Resolved: Identifiable {
            public let source: Source
            public var id: UUID { \(raw: idBody) }
            \(raw: props)
        }
        """
    }
    
    private static func createResolverStruct(allProperties: [VariableDeclSyntax],
                                             fullOverrides: [VariableDeclSyntax],
                                             nestedOverrides: [String: [(leafName: String, leafType: String)]],
                                             hasDefinition: Bool,
                                             hasInstance: Bool
    ) -> DeclSyntax {
        
        let fullOverrideSet = Set(fullOverrides.compactMap { $0.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text })
        let nestedOverrideSet = Set(nestedOverrides.keys)
        
        let resolvedFromDefArgs = allProperties.map { p -> String in
            guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return "" }
            
            if fullOverrideSet.contains(n) {
                return "\(n): override?.\(n) ?? def.\(n)"
            } else if nestedOverrideSet.contains(n) {
                let mutations = nestedOverrides[n, default: []].map {
                    "if let v = override?.\(n)_\($0.leafName) { value.\($0.leafName) = v }"
                }.joined(separator: "\n                ")
                return """
            \(n): {
                    var value = def.\(n)
                    \(mutations)
                    return value
                }()
            """
            } else {
                return "\(n): def.\(n)"
            }
        }.joined(separator: ",\n                ")
        
        let resolvedFromInstArgs = allProperties.compactMap { p -> String? in
            guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return nil }
            return "\(n): inst.\(n)"
        }.joined(separator: ",\n                         ")
        
        // Helpers (private)
        let helperFromDef = hasDefinition ? """
    private static func _resolve(def: Definition, override: Override?) -> Resolved {
        return Resolved(
            source: .definition(definition: def),
            \(resolvedFromDefArgs)
        )
    }
    """ : ""
        
        let helperFromInst = hasInstance ? """
    private static func _resolve(inst: Instance) -> Resolved {
        return Resolved(
            source: .instance(instance: inst),
            \(resolvedFromInstArgs)
        )
    }
    """ : ""
        
        // Scalar overloads
        let scalarFromDef = hasDefinition ? """
    public static func resolve(definition: Definition, override: Override? = nil) -> Resolved {
        _resolve(def: definition, override: override)
    }
    """ : ""
        
        let scalarFromInst = hasInstance ? """
    public static func resolve(instance: Instance) -> Resolved {
        _resolve(inst: instance)
    }
    """ : ""
        
        // Array overloads
        let arrayFromDefs = hasDefinition ? """
    public static func resolve(definitions: [Definition], overrides: [Override] = []) -> [Resolved] {
        let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })
        return definitions.map { def in
            _resolve(def: def, override: overrideDict[def.id])
        }
    }
    """ : ""
        
        let arrayFromInsts = hasInstance ? """
    public static func resolve(instances: [Instance]) -> [Resolved] {
        return instances.map { _resolve(inst: $0) }
    }
    """ : ""
        
        // Combined entry point (kept for compatibility)
        var params: [String] = []
        if hasDefinition { params.append("definitions: [Definition] = []") }
        if hasDefinition { params.append("overrides: [Override] = []") }
        if hasInstance { params.append("instances: [Instance] = []") }
        
        var body: [String] = []
        var returnStatement: String = ""
        
        if hasDefinition {
            body.append("let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })")
            body.append("""
        let fromDefs = definitions.map { def -> Resolved in
            let override = overrideDict[def.id]
            return Resolved(
                source: .definition(definition: def),
                \(resolvedFromDefArgs)
            )
        }
        """)
        }
        
        if hasInstance {
            body.append("""
        let fromInsts = instances.map { inst -> Resolved in
            return Resolved(
                source: .instance(instance: inst),
                \(resolvedFromInstArgs)
            )
        }
        """)
        }
        
        switch (hasDefinition, hasInstance) {
        case (true, true): returnStatement = "return fromDefs + fromInsts"
        case (true, false): returnStatement = "return fromDefs"
        case (false, true): returnStatement = "return fromInsts"
        default: returnStatement = "return []"
        }
        
        let mainResolver = """
    public static func resolve(\(params.joined(separator: ", "))) -> [Resolved] {
        \(body.joined(separator: "\n        "))
        \(returnStatement)
    }
    """
        
        return """
    public struct Resolver {
        \(raw: helperFromDef.isEmpty ? "" : helperFromDef + "\n\n    ")
        \(raw: helperFromInst.isEmpty ? "" : helperFromInst + "\n\n    ")
        \(raw: scalarFromDef.isEmpty ? "" : scalarFromDef + "\n\n    ")
        \(raw: scalarFromInst.isEmpty ? "" : scalarFromInst + "\n\n    ")
        \(raw: arrayFromDefs.isEmpty ? "" : arrayFromDefs + "\n\n    ")
        \(raw: arrayFromInsts.isEmpty ? "" : arrayFromInsts + "\n\n    ")
        \(raw: mainResolver)
    }
    """
    }
    
    
    
    // MARK: - Helper Functions
    private static func parsePattern(from node: AttributeSyntax) -> ResolvablePattern {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let patternArg = args.first(where: { $0.label?.text == "pattern" })
        else { return .full }
        if patternArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines).contains("nonInstantiable") {
            return .nonInstantiable
        }
        return .full
    }
    
    private static func extractTypeName(from expr: ExprSyntax) -> String? {
        let text = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".self") { return String(text.dropLast(5)) }
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

// MARK: - Diagnostics & Plugin Boilerplate
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

extension KeyPathExprSyntax {
    var lastComponentName: String? {
        self.components.last?.component.as(KeyPathPropertyComponentSyntax.self)?.declName.baseName.text
    }
}
