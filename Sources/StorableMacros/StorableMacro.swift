// Sources/StorableMacros/StorableMacro.swift
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

// FIX: move Prop out of the generic function
private struct Prop {
    let name: String
    let type: String
    let inDefinition: Bool
    let inInstance: Bool
}

public struct StorableMacro: MemberMacro, MemberAttributeMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
        let baseName = structDecl.name.text

        // Accumulators
        var props: [Prop] = []                                  // simple value props (with Definition/Instance flags)
        var allInitParams: [(name: String, type: String)] = []  // for the unavailable base init signature

        // Relationship accumulators (Definition/Instance)
        var defRelDecls: [String] = []
        var instRelDecls: [String] = []
        var defRelInitParams: [String] = []
        var instRelInitParams: [String] = []

        // Walk stored properties in the base struct
        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let typeText = binding.typeAnnotation?.type.trimmedDescription
            else { continue }

            // Always include original signature param for the blocked base init
            allInitParams.append((name: name, type: typeText))

            // Handle @StorableRelationship if present
            if let (_, cfg) = parseStorableRelationshipAttribute(varDecl.attributes),
               let info = analyzeRelationshipType(typeText) {

                switch cfg.source {
                case .storable:
                    // This case was already correct and remains unchanged.
                    let defType = mapRelatedType(info, suffix: "Definition")
                    let instType = mapRelatedType(info, suffix: "Instance")

                    var relArgs: [String] = []
                    if let d = cfg.deleteRuleExpr { relArgs.append("deleteRule: \(d)") }
                    if let inv = cfg.inverseExpr {
                        let rewritten = rewriteInverseKeyPathToDefinition(inv)
                        relArgs.append("inverse: \(rewritten)")
                    }
                    let relAttr = relArgs.isEmpty ? "@Relationship" : "@Relationship(\(relArgs.joined(separator: ", ")))"

                    defRelDecls.append("\(relAttr)\n    var \(name): \(defType)")
                    instRelDecls.append("var \(name): \(instType)")
                    defRelInitParams.append("\(name): \(defType)")
                    instRelInitParams.append("\(name): \(instType)")

                case .resolvable:
                    // --- CORRECTED LOGIC STARTS HERE ---

                    // 1. The Definition always holds the canonical `.Definition` of the nested type.
                    //    This part is the same as the .storable case.
                    let defType = mapRelatedType(info, suffix: "Definition")
                    defRelDecls.append("var \(name): \(defType)")
                    defRelInitParams.append("\(name): \(defType)")

                    // 2. The Instance holds an optional `.Override` of the nested type, not a full .Instance.
                    //    This is the key change that enables the override pattern.
                    let overrideType = mapRelatedType(info, suffix: "Override")
                    let overrideName = "\(name)Override" // e.g., "typeOverride"

                    // The property in the Instance is optional, as an override may not exist.
                    instRelDecls.append("var \(overrideName): \(overrideType)?")
                    
                    // The override is an optional parameter to the Instance's initializer, defaulting to nil.
                    // This allows creating an instance without necessarily providing an override immediately.
                    instRelInitParams.append("\(overrideName): \(overrideType)? = nil")
                    
                    // --- CORRECTED LOGIC ENDS HERE ---
                }

                // Do not add this to simple value props
                continue
            }

            // Not a relationship: honor DefinitionStored / InstanceStored markers
            let markers = markersForAttributes(varDecl.attributes)
            if markers == .both {
                context.diagnose(Diagnostic(
                    node: Syntax(varDecl),
                    message: StorableMessage(
                        id: "conflictingMarkers",
                        message: "Property '\(name)' cannot be annotated with both @DefinitionStored and @InstanceStored.",
                        severity: .error
                    )
                ))
            }

            let inDef: Bool
            let inInst: Bool
            switch markers {
            case .none:
                inDef = true; inInst = true
            case .definitionOnly:
                inDef = true; inInst = false
            case .instanceOnly:
                inDef = false; inInst = true
            case .both:
                inDef = true; inInst = true
            }

            props.append(Prop(name: name, type: typeText, inDefinition: inDef, inInstance: inInst))
        }

        // Partition for generators
        let defProps = props.filter { $0.inDefinition }
        let instProps = props.filter { $0.inInstance }

        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(
            baseName: baseName,
            propsInfo: allInitParams
        ))
        decls.append(createDefinitionClass(
            defProps: defProps,
            relDecls: defRelDecls,
            relInitParams: defRelInitParams
        ))
        decls.append(createInstanceClass(
            instProps: instProps,
            relDecls: instRelDecls,
            relInitParams: instRelInitParams
        ))
        decls.append(createSourceEnum())
        decls.append(createResolvedStruct(props: props))
        decls.append(createResolverStruct())

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
                   message: "Do not instantiate \(raw: baseName) directly. Use generated nested types instead.")
        """
        return [attr]
    }

    // MARK: - Generation

    private static func createBlockingUnavailableInit(baseName: String,
                                                      propsInfo: [(name: String, type: String)]) -> DeclSyntax {
        let params = propsInfo.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        return DeclSyntax(stringLiteral: """
        @available(*, unavailable,
                   message: "Do not instantiate '\(baseName)'. Use generated nested types instead.")
        public init(\(params)) { fatalError("This initializer cannot be called.") }
        """)
    }

    // Accept [Prop] now
    private static func createDefinitionClass(
        defProps: [Prop],
        relDecls: [String],
        relInitParams: [String]
    ) -> DeclSyntax {
        let propsBlock = defProps.map { "var \($0.name): \($0.type)" }
                                 .joined(separator: "\n\n    ")
        let relBlock = relDecls.joined(separator: "\n\n    ")

        let initParamsList =
            ["uuid: UUID"]
            + defProps.map { "\($0.name): \($0.type)" }
            + relInitParams
        let initParams = initParamsList.joined(separator: ", ")

        func names(from params: [String]) -> [String] {
            params.compactMap { $0.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) } }
        }

        let assignsLines =
            ["self.uuid = uuid"]
            + defProps.map { "self.\($0.name) = \($0.name)" }
            + names(from: relInitParams).map { "self.\($0) = \($0)" }
        let assigns = assignsLines.joined(separator: "\n        ")

        // Build body members with conditional empty sections handled by simple joins
        let bodyMembers = [propsBlock, relBlock]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n    ")

        return DeclSyntax("""
        @Model
        public final class Definition {
            @Attribute(.unique)
            var uuid: UUID

            \(raw: bodyMembers)

            public init(\(raw: initParams)) {
                \(raw: assigns)
            }
        }
        """)
    }

    // Instance: @Observable final class with Codable, Identifiable, Hashable + relationships
    private static func createInstanceClass(
        instProps: [Prop],
        relDecls: [String],
        relInitParams: [String]
    ) -> DeclSyntax {
        let propsBlock = instProps.map { "var \($0.name): \($0.type)" }
                                  .joined(separator: "\n\n    ")
        let relBlock = relDecls.joined(separator: "\n\n    ")

        let initParamsList =
            ["id: UUID = UUID()", "definitionUUID: UUID"]
            + instProps.map { "\($0.name): \($0.type)" }
            + relInitParams
        let initParams = initParamsList.joined(separator: ", ")

        func names(from params: [String]) -> [String] {
            params.compactMap { $0.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) } }
        }

        let assignsLines =
            ["self.id = id", "self.definitionUUID = definitionUUID"]
            + instProps.map { "self.\($0.name) = \($0.name)" }
            + names(from: relInitParams).map { "self.\($0) = \($0)" }
        let assigns = assignsLines.joined(separator: "\n        ")

        let bodyMembers = [propsBlock, relBlock]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n    ")

        return DeclSyntax("""
        @Observable
        public final class Instance: Codable, Hashable, Identifiable {
            public var id: UUID = UUID()
            public var definitionUUID: UUID

            \(raw: bodyMembers)

            public init(\(raw: initParams)) {
                \(raw: assigns)
            }

            public static func == (lhs: Instance, rhs: Instance) -> Bool { lhs.id == rhs.id }
            public func hash(into hasher: inout Hasher) { hasher.combine(id) }
        }
        """)
    }

    private static func createSourceEnum() -> DeclSyntax {
        DeclSyntax("""
        public enum Source: Hashable {
            case definition(definitionUUID: UUID)
            case instance(instanceID: UUID)
        }
        """)
    }

    // Accept [Prop] now
    private static func createResolvedStruct(props: [Prop]) -> DeclSyntax {
        let computedProps = props.map { p -> String in
            switch (p.inDefinition, p.inInstance) {
            case (true, true):
                return """
                public var \(p.name): \(p.type) {
                    if let inst = instance { return inst.\(p.name) }
                    return definition.\(p.name)
                }
                """
            case (true, false):
                return """
                public var \(p.name): \(p.type) { definition.\(p.name) }
                """
            case (false, true):
                return """
                public var \(p.name): \(p.type)? { instance?.\(p.name) }
                """
            default:
                return ""
            }
        }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID {
                switch source {
                case .definition(let defUUID): return defUUID
                case .instance(let instID): return instID
                }
            }
            public let source: Source
            public let definition: Definition
            public let instance: Instance?

            \(raw: computedProps)
        }
        """)
    }

    private static func createResolverStruct() -> DeclSyntax {
        let single = """
        public static func resolve(definition: Definition, instance: Instance?) -> Resolved {
            let src: Source = instance != nil
                ? .instance(instanceID: instance!.id)
                : .definition(definitionUUID: definition.uuid)
            return Resolved(source: src, definition: definition, instance: instance)
        }
        """

        let batch = """
        public static func resolve(definitions: [Definition], instances: [Instance] = []) -> [Resolved] {
            let instancesByDefUUID = Dictionary(grouping: instances, by: { $0.definitionUUID })
            return definitions.map { def in
                let inst = instancesByDefUUID[def.uuid]?.first
                return resolve(definition: def, instance: inst)
            }
        }
        """

        return DeclSyntax("""
        public struct Resolver {
            \(raw: single)

            \(raw: batch)
        }
        """)
    }
}

// MARK: - Attribute marker parsing

private enum MarkerUse {
    case none
    case definitionOnly
    case instanceOnly
    case both
}

private func markersForAttributes(_ attributes: AttributeListSyntax?) -> MarkerUse {
    guard let attributes, !attributes.isEmpty else { return .none }
    var sawDef = false
    var sawInst = false

    // SwiftSyntax 600: elements are AttributeSyntax
    for element in attributes {
        guard let attr = element.as(AttributeSyntax.self) else { continue }
        let rawName = attr.attributeName.trimmedDescription
        let simpleName = rawName.split(separator: ".").last.map(String.init) ?? rawName
        if simpleName == "DefinitionStored" { sawDef = true }
        if simpleName == "InstanceStored" { sawInst = true }
    }

    switch (sawDef, sawInst) {
    case (false, false): return .none
    case (true, false):  return .definitionOnly
    case (false, true):  return .instanceOnly
    case (true, true):   return .both
    }
}

private enum RelationshipSource { case storable, resolvable }

private struct RelationshipConfig {
    var source: RelationshipSource = .storable
    var deleteRuleExpr: String? = nil     // raw expr text (e.g., ".nullify")
    var inverseExpr: String? = nil        // raw expr text (e.g., "\Symbol.components")
}

// Detect @StorableRelationship and parse its arguments
private func parseStorableRelationshipAttribute(_ attrs: AttributeListSyntax?) -> (attr: AttributeSyntax, config: RelationshipConfig)? {
    guard let attrs, !attrs.isEmpty else { return nil }
    for element in attrs {
        guard let attr = element.as(AttributeSyntax.self) else { continue }
        let rawName = attr.attributeName.trimmedDescription
        let simpleName = rawName.split(separator: ".").last.map(String.init) ?? rawName
        guard simpleName == "StorableRelationship" else { continue }

        var cfg = RelationshipConfig()
        if let args = attr.arguments, case let .argumentList(list) = args {
            for a in list {
                let label = a.label?.text ?? ""
                let exprText = a.expression.trimmedDescription
                switch label {
                case "source":
                    // Accept ".resolvable" or fully-qualified; fallback to .storable
                    cfg.source = exprText.contains("resolvable") ? .resolvable : .storable
                case "deleteRule":
                    cfg.deleteRuleExpr = exprText
                case "inverse":
                    cfg.inverseExpr = exprText
                default:
                    break
                }
            }
        }
        return (attr, cfg)
    }
    return nil
}

private enum ContainerKind { case single, optional, array, arrayOptional, set, setOptional }

private struct RelationshipTypeInfo {
    let base: String     // e.g. "Symbol"
    let container: ContainerKind
}

private func analyzeRelationshipType(_ typeText: String) -> RelationshipTypeInfo? {
    var t = typeText.trimmingCharacters(in: .whitespacesAndNewlines)
    var opt = false
    if t.hasSuffix("?") {
        opt = true
        t.removeLast()
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if t.hasPrefix("[") && t.hasSuffix("]") {
        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return RelationshipTypeInfo(base: inner, container: opt ? .arrayOptional : .array)
    }
    if t.hasPrefix("Set<") && t.hasSuffix(">") {
        let inner = String(t.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return RelationshipTypeInfo(base: inner, container: opt ? .setOptional : .set)
    }
    return RelationshipTypeInfo(base: t, container: opt ? .optional : .single)
}

private func mapRelatedType(_ info: RelationshipTypeInfo, suffix: String) -> String {
    func attach(_ base: String) -> String {
        // If base already ends with ".Definition" / ".Instance", leave as-is
        if base.hasSuffix(".Definition") || base.hasSuffix(".Instance") { return base }
        return "\(base).\(suffix)"
    }
    let mappedBase = attach(info.base)
    switch info.container {
    case .single:         return mappedBase
    case .optional:       return "\(mappedBase)?"
    case .array:          return "[\(mappedBase)]"
    case .arrayOptional:  return "[\(mappedBase)]?"
    case .set:            return "Set<\(mappedBase)>"
    case .setOptional:    return "Set<\(mappedBase)>?"
    }
}

// Rewrite e.g. \Symbol.components -> \Symbol.Definition.components (keeps module qualification)
private func rewriteInverseKeyPathToDefinition(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.first == "\\" else { return raw }
    if s.contains(".Definition.") { return s } // already qualified
    // Split by '.' after removing leading '\'
    let noSlash = String(s.dropFirst())
    var parts = noSlash.split(separator: ".").map(String.init)
    // Insert "Definition" before first lowerCamel component (property path)
    if let idx = parts.firstIndex(where: { guard let c = $0.first else { return false }; return c.isLowercase }) {
        if idx > 0 { parts.insert("Definition", at: idx) }
    } else {
        // No lowerCamel found; append
        parts.append("Definition")
    }
    return "\\" + parts.joined(separator: ".")
}

// MARK: - Diagnostics

private struct StorableMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(domain: String = "Storable", id: String, message: String, severity: DiagnosticSeverity) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id)
        self.severity = severity
    }
}

@main
struct StorableMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [StorableMacro.self]
}

extension SyntaxProtocol {
    var trimmedDescription: String {
        self.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
