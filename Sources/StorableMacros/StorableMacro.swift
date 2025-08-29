// Sources/StorableMacros/StorableMacro.swift
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

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

        var props: [Prop] = []
        var allInitParams: [(name: String, type: String)] = []

        var defRelDecls: [String] = []
        var instRelDecls: [String] = []
        var defRelInitParams: [String] = []
        var instRelInitParams: [String] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let typeText = binding.typeAnnotation?.type.trimmedDescription
            else { continue }

            allInitParams.append((name: name, type: typeText))

            if let (_, cfg) = parseStorableRelationshipAttribute(varDecl.attributes),
               let info = analyzeRelationshipType(typeText) {

                switch cfg.source {
                case .storable:
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
                    let defType = mapRelatedType(info, suffix: "Definition")
                    defRelDecls.append("var \(name): \(defType)")
                    defRelInitParams.append("\(name): \(defType)")

                    let overrideType = mapRelatedType(info, suffix: "Override")
                    let overrideName = "\(name)Override"

                    instRelDecls.append("var \(overrideName): \(overrideType)?")
                    instRelInitParams.append("\(overrideName): \(overrideType)? = nil")
                }
                continue
            }

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

    private static func createResolvedStruct(props: [Prop]) -> DeclSyntax {
        let computedProps = props.map { p -> String in
            switch (p.inDefinition, p.inInstance) {
            case (true, true):
                return "public var \(p.name): \(p.type) { instance.\(p.name) }"
            case (true, false):
                return "public var \(p.name): \(p.type) { definition.\(p.name) }"
            case (false, true):
                return "public var \(p.name): \(p.type) { instance.\(p.name) }"
            default:
                return ""
            }
        }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID { instance.id }
            public let source: Source
            public let definition: Definition
            public let instance: Instance

            \(raw: computedProps)
        }
        """)
    }

    private static func createResolverStruct() -> DeclSyntax {
        let single = """
        public static func resolve(definition: Definition, instance: Instance) -> Resolved {
            return Resolved(source: .instance(instanceID: instance.id), definition: definition, instance: instance)
        }
        """

        let batch = """
        public static func resolve(definitions: [Definition], instances: [Instance]) -> [Resolved] {
            let instancesByDefUUID = Dictionary(grouping: instances, by: { $0.definitionUUID })
            return definitions.compactMap { def in
                guard let inst = instancesByDefUUID[def.uuid]?.first else {
                    return nil
                }
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
    var deleteRuleExpr: String? = nil
    var inverseExpr: String? = nil
}

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
    let base: String
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
        if base.hasSuffix(".Definition") || base.hasSuffix(".Instance") || base.hasSuffix(".Override") { return base }
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

private func rewriteInverseKeyPathToDefinition(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.first == "\\" else { return raw }
    if s.contains(".Definition.") { return s }
    let noSlash = String(s.dropFirst())
    var parts = noSlash.split(separator: ".").map(String.init)
    if let idx = parts.firstIndex(where: { guard let c = $0.first else { return false }; return c.isLowercase }) {
        if idx > 0 { parts.insert("Definition", at: idx) }
    } else {
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
