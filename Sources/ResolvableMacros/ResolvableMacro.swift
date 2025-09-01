import Foundation
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ResolvableMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {

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
        var includeOverrideFields: Bool
    }

    // MARK: - Extension conformance generation
    // Emits: extension <Base>: Resolvable { typealias ... }
    // Only when pattern == .full (Instance exists).
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Only attach to structs annotated with @Resolvable
        guard declaration.is(StructDeclSyntax.self) else { return [] }

        // Respect the pattern: only add Resolvable conformance in `.full`
        let pattern = parsePattern(from: node)
        guard pattern == .full else { return [] }

        // Build: extension <Base>: Resolvable {}
        let inheritance = InheritanceClauseSyntax {
            InheritedTypeSyntax(type: IdentifierTypeSyntax(name: .identifier("Resolvable")))
        }

        let ext = ExtensionDeclSyntax(
            extendedType: type.trimmed,
            inheritanceClause: inheritance,
            memberBlock: MemberBlockSyntax(members: MemberBlockItemListSyntax([]))
        )

        return [ext]
    }

    // MARK: - Member generation
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
            generateFlags = GenerateFlags(
                hasDefinition: true,
                hasInstance: true,
                includeOverrideFields: true
            )
        case .nonInstantiable:
            generateFlags = GenerateFlags(
                hasDefinition: true,
                hasInstance: false,
                includeOverrideFields: true
            )
        }

        var defaultBehavior: ResolvableDefault = .identity
        if let args = node.arguments?.as(LabeledExprListSyntax.self),
           let defaultArg = args.first(where: { $0.label?.text == "default" }) {
            let text = defaultArg.expression.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
                $0.as(AttributeSyntax.self)?
                    .attributeName.description
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "Overridable"
            }?.as(AttributeSyntax.self)

            let hasIdentity = varDecl.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.description
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "Identity"
            }
            let hasOverridable = (overridableAttr != nil)

            // Strip marker attributes from the property as they are compile-time only.
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

            guard let propName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text, !propName.isEmpty else {
                continue
            }

            // Full-field override (no arguments)
            guard let attr = overridableAttr,
                  let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  !args.isEmpty
            else {
                fullOverrides.append(cleanedVarDecl)
                continue
            }

            // Nested override: @Overridable(\Parent.leaf, as: LeafType.self)
            let keyPathExpr = args.lazy.compactMap { $0.expression.as(KeyPathExprSyntax.self) }.first
            guard let kp = keyPathExpr else { continue }
            guard let leafName = kp.lastComponentName, !leafName.isEmpty else { continue }

            let asExpr = args.first(where: { $0.label?.text == "as" })?.expression
            guard let leafTypeText = asExpr.flatMap(Self.extractTypeName(from:)), !leafTypeText.isEmpty else { continue }

            nestedOverrides[propName, default: []]
                .append((leafName: leafName, leafType: leafTypeText))
        }

        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(baseName: baseName, properties: allProperties))

        if generateFlags.hasDefinition {
            decls.append(createDefinitionStruct(properties: allProperties))
            decls.append(
                createOverrideStruct(
                    baseName: baseName,
                    fullOverrides: fullOverrides,
                    nestedOverrides: nestedOverrides,
                    includeFields: generateFlags.includeOverrideFields
                )
            )
        }
        if generateFlags.hasInstance {
            decls.append(createInstanceStruct(properties: allProperties))
        }

        if generateFlags.hasDefinition || generateFlags.hasInstance {
            decls.append(createSourceEnum(hasDefinition: generateFlags.hasDefinition, hasInstance: generateFlags.hasInstance))
            decls.append(
                createResolvedStruct(
                    baseName: baseName,
                    properties: allProperties,
                    hasDefinition: generateFlags.hasDefinition,
                    hasInstance: generateFlags.hasInstance
                )
            )
            decls.append(
                createResolverStruct(
                    baseName: baseName,
                    allProperties: allProperties,
                    fullOverrides: fullOverrides,
                    nestedOverrides: nestedOverrides,
                    hasDefinition: generateFlags.hasDefinition,
                    hasInstance: generateFlags.hasInstance
                )
            )
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

    // MARK: - Generation helpers

    private static func createBlockingUnavailableInit(baseName: String, properties: [VariableDeclSyntax]) -> DeclSyntax {
        let params = properties.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let t = b.typeAnnotation?.type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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

        let updates = properties.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { return nil }
            return "self.\(name) = resolved.\(name)"
        }.joined(separator: "\n        ")

        return """
        public struct Instance: Identifiable, Codable, Hashable, UpdatableFromResolved {
            public var id: UUID = UUID()
            \(raw: props)

            public typealias ResolvedType = Resolved

            public mutating func update(from resolved: Resolved) {
                \(raw: updates)
            }
        }
        """
    }

    private static func createOverrideStruct(
        baseName: String,
        fullOverrides: [VariableDeclSyntax],
        nestedOverrides: [String: [(leafName: String, leafType: String)]],
        includeFields: Bool
    ) -> DeclSyntax {
        var fields: [String] = []
        if includeFields {
            for p in fullOverrides {
                guard let b = p.bindings.first,
                      let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let t = b.typeAnnotation?.type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
            let name = line
                .replacingOccurrences(of: "public var ", with: "")
                .split(separator: ":")[0]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return "self.\(name) = \(name)"
        }
        let assignsBlock = assigns.isEmpty ? "" : "\n        " + assigns.joined(separator: "\n        ")

        let updateLinesFull = fullOverrides.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { return nil }
            return "self.\(n) = resolved.\(n)"
        }

        let updateLinesNested = nestedOverrides.flatMap { parent, nested in
            nested.map { leaf in
                "self.\(parent)_\(leaf.leafName) = resolved.\(parent).\(leaf.leafName)"
            }
        }

        let updateBody = (updateLinesFull + updateLinesNested).joined(separator: "\n            ")

        let initFromArgsFull = fullOverrides.compactMap { p -> String? in
            guard let b = p.bindings.first,
                  let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { return nil }
            return "\(n): resolved.\(n)"
        }

        let initFromArgsNested = nestedOverrides.flatMap { parent, nested in
            nested.map { leaf in
                "\(parent)_\(leaf.leafName): resolved.\(parent).\(leaf.leafName)"
            }
        }

        let initFromArgsList = (initFromArgsFull + initFromArgsNested).joined(separator: ",\n            ")
        let initFromArgsBlock = initFromArgsList.isEmpty ? "" : ",\n            " + initFromArgsList

        return """
        public struct Override: Identifiable, Codable, Hashable, OverrideProtocol, UpdatableFromResolved, CreatableFromResolved {
            public let definitionID: UUID
            public var id: UUID { definitionID }\(raw: fieldsBlock)

            public init(definitionID: UUID\(raw: paramsBlock)) {
                self.definitionID = definitionID\(raw: assignsBlock)
            }

            public typealias ResolvedType = Resolved

            // Update only the fields declared overridable.
            public mutating func update(from resolved: Resolved) {
                \(raw: updateBody)
            }

            // Create an override from a definition-backed Resolved.
            public init(from resolved: Resolved) {
                switch resolved.source {
                case .definition(let d):
                    self.init(
                        definitionID: d.id\(raw: initFromArgsBlock)
                    )
                case .instance:
                    preconditionFailure("Cannot create an Override from an instance-based Resolved")
                }
            }
        }
        """
    }

    private static func createSourceEnum(hasDefinition: Bool, hasInstance: Bool) -> DeclSyntax {
        var cases: [String] = []
        if hasDefinition {
            cases.append("case definition(definition: Definition)")
        }
        if hasInstance {
            cases.append("case instance(instance: Instance)")
        }
        return """
        public enum Source: Hashable {
            \(raw: cases.joined(separator: "\n    "))
        }
        """
    }

    private static func createResolvedStruct(
        baseName: String,
        properties: [VariableDeclSyntax],
        hasDefinition: Bool,
        hasInstance: Bool
    ) -> DeclSyntax {
        let props = properties.map { $0.description }.joined(separator: "\n\n    ")
        let idBody: String = {
            switch (hasDefinition, hasInstance) {
            case (true, true):
                return "switch source { case .definition(let d): return d.id; case .instance(let i): return i.id }"
            case (true, false):
                return "if case let .definition(d) = source { return d.id }; fatalError(\"Invalid source\")"
            case (false, true):
                return "if case let .instance(i) = source { return i.id }; fatalError(\"Invalid source\")"
            default:
                return "fatalError(\"No sources available\")"
            }
        }()

        let header: String = hasInstance
        ? "public struct Resolved: Identifiable, ResolvedProtocol {"
        : "public struct Resolved: Identifiable {"

        // Typealiases for protocol associated types
        let typealiases: String = hasInstance ? """
            // Bind ResolvedProtocol associated types to enclosing nested types
            public typealias Source = \(baseName).Source
            public typealias Override = \(baseName).Override
            public typealias Instance = \(baseName).Instance
        """ : """
            public typealias Source = \(baseName).Source
        """

        // Only generate apply/remove when we have instances (i.e. full pattern).
        let applyRemove: String = hasInstance ? """
            public func apply(toOverrides: inout [Override], andInstances: inout [Instance]) {
                switch source {
                case .definition(let d):
                    if let idx = toOverrides.firstIndex(where: { $0.definitionID == d.id }) {
                        // Found an existing override; update it in place.
                        toOverrides[idx].update(from: self)
                    } else {
                        // Create a new override only when needed.
                        let newOverride = Override(from: self)
                        toOverrides.append(newOverride)
                    }
                case .instance(let i):
                    if let idx = andInstances.firstIndex(where: { $0.id == i.id }) {
                        andInstances[idx].update(from: self)
                    } else {
                        // No CreatableFromResolved for Instance by design; skip creation.
                    }
                }
            }

            public func remove(fromOverrides: inout [Override], andInstances: inout [Instance]) {
                switch source {
                case .definition(let d):
                    if let idx = fromOverrides.firstIndex(where: { $0.definitionID == d.id }) {
                        fromOverrides.remove(at: idx)
                    }
                case .instance(let i):
                    if let idx = andInstances.firstIndex(where: { $0.id == i.id }) {
                        andInstances.remove(at: idx)
                    }
                }
            }
        """ : ""

        return """
        \(raw: header)
            \(raw: typealiases)

            public let source: Source
            public var id: UUID { \(raw: idBody) }
            \(raw: props)

            \(raw: applyRemove)
        }
        """
    }

    private static func createResolverStruct(
        baseName: String,
        allProperties: [VariableDeclSyntax],
        fullOverrides: [VariableDeclSyntax],
        nestedOverrides: [String: [(leafName: String, leafType: String)]],
        hasDefinition: Bool,
        hasInstance: Bool
    ) -> DeclSyntax {

        let fullOverrideSet = Set(
            fullOverrides.compactMap { $0.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
        )
        let nestedOverrideSet = Set(nestedOverrides.keys)

        let resolvedFromDefArgs = allProperties.map { p -> String in
            guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return ""
            }
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
            guard let n = p.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return nil
            }
            return "\(n): inst.\(n)"
        }.joined(separator: ",\n                         ")

        // Helpers
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

        // Combined entry point (required by ResolverProtocol), only when both kinds exist
        let mainResolver: String = {
            guard hasDefinition && hasInstance else { return "" }
            return """
        public static func resolve(definitions: [Definition] = [], overrides: [Override] = [], instances: [Instance] = []) -> [Resolved] {
            let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.definitionID, $0) })
            let fromDefs = definitions.map { def -> Resolved in
                _resolve(def: def, override: overrideDict[def.id])
            }
            let fromInsts = instances.map { inst -> Resolved in
                _resolve(inst: inst)
            }
            return fromDefs + fromInsts
        }
        """
        }()

        // Protocol conformance header and associated typealiases (only valid in .full)
        let header: String = hasDefinition && hasInstance
        ? "public struct Resolver: ResolverProtocol {"
        : "public struct Resolver {"

        let typealiasesBlock: String = hasDefinition && hasInstance ? """
        // Bind ResolverProtocol associated types
        public typealias Definition = \(baseName).Definition
        public typealias Instance   = \(baseName).Instance
        public typealias Override   = \(baseName).Override
        public typealias Resolved   = \(baseName).Resolved
        """ : ""

        // Assemble sections conditionally
        var sections: [String] = []
        if !typealiasesBlock.isEmpty { sections.append(typealiasesBlock) }
        if !helperFromDef.isEmpty { sections.append(helperFromDef) }
        if !helperFromInst.isEmpty { sections.append(helperFromInst) }
        if !scalarFromDef.isEmpty { sections.append(scalarFromDef) }
        if !scalarFromInst.isEmpty { sections.append(scalarFromInst) }
        if !arrayFromDefs.isEmpty { sections.append(arrayFromDefs) }
        if !arrayFromInsts.isEmpty { sections.append(arrayFromInsts) }
        if !mainResolver.isEmpty { sections.append(mainResolver) }

        return """
    \(raw: header)
        \(raw: sections.joined(separator: "\n\n        "))
    }
    """
    }

    // MARK: - Helper Functions
    private static func parsePattern(from node: AttributeSyntax) -> ResolvablePattern {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let patternArg = args.first(where: { $0.label?.text == "pattern" })
        else { return .full }
        if patternArg.expression.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).contains("nonInstantiable") {
            return .nonInstantiable
        }
        return .full
    }

    private static func extractTypeName(from expr: ExprSyntax) -> String? {
        let text = expr.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if text.hasSuffix(".self") { return String(text.dropLast(5)) }
        return text
    }
}

// Diagnostics

private func diagnoseError(_ context: some MacroExpansionContext,
                           node: Syntax,
                           id: String,
                           message: String) {
    context.diagnose(
        Diagnostic(
            node: node,
            message: ResolvableMessage(
                id: id,
                message: message,
                severity: .error
            )
        )
    )
}

// MARK: - Diagnostics & Plugin Boilerplate
private struct ResolvableMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    init(
        domain: String = "Resolvable",
        id: String,
        message: String,
        severity: DiagnosticSeverity
    ) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id)
        self.severity = severity
    }
}

@main
struct ResolvableMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ResolvableMacro.self,
        ResolvableDestinationMacro.self,
        DefinitionSourceMacro.self
    ]
}

extension KeyPathExprSyntax {
    var lastComponentName: String? {
        self.components.last?.component
            .as(KeyPathPropertyComponentSyntax.self)?
            .declName.baseName.text
    }
}
