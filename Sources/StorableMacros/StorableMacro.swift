import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct StorableMacro: MemberMacro, MemberAttributeMacro {

    // MARK: - Private Helper Structs
    private struct Prop {
        let name: String
        let type: String
        let inDefinition: Bool
        let inInstance: Bool
    }

    private struct RelationInfo {
        let name: String
        let baseTypeName: String
        let isCollection: Bool
        let isResolvable: Bool
        let instanceComponents: [String]
    }
    
    private enum MarkerUse {
        case none
        case definitionOnly
        case instanceOnly
        case both
    }
    
    private enum ContainerKind { case single, optional, array, arrayOptional, set, setOptional }

    private struct RelationshipTypeInfo {
        let base: String
        let container: ContainerKind
    }

    // MARK: - Main Expansion Logic
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
        let baseName = structDecl.name.text

        var props: [Prop] = []
        var relations: [RelationInfo] = []
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

            if let resolvableAttr = findAttribute(named: "ResolvableProperty", in: varDecl.attributes) {
                guard let info = analyzeRelationshipType(typeText) else { continue }
                var instanceComponents: [String] = []
                let isCollection = info.container == .array || info.container == .set

                if let defArg = findArgument(labeled: "definition", in: resolvableAttr),
                   let defTypeName = extractTypeName(from: defArg.expression) {
                    let finalDefType = applyContainer(info.container, to: defTypeName)
                    defRelDecls.append("var \(name): \(finalDefType)")
                    defRelInitParams.append("\(name): \(finalDefType)")
                }

                if let instArg = findArgument(labeled: "instance", in: resolvableAttr),
                   let arrayExpr = instArg.expression.as(ArrayExprSyntax.self) {
                    for element in arrayExpr.elements {
                        guard let instTypeName = extractTypeName(from: element.expression) else { continue }
                        let suffix = instTypeName.split(separator: ".").last.map(String.init) ?? ""
                        instanceComponents.append(suffix)
                        
                        let propertyName = isCollection ? "\(name)\(suffix)s" : "\(name)\(suffix)"
                        var finalInstType = applyContainer(info.container, to: instTypeName)
                        if !isCollection { finalInstType += "?" }
                        let defaultValue = isCollection ? "[]" : "nil"

                        instRelDecls.append("var \(propertyName): \(finalInstType)")
                        instRelInitParams.append("\(propertyName): \(finalInstType) = \(defaultValue)")
                    }
                }
                
                relations.append(.init(
                    name: name,
                    baseTypeName: info.base,
                    isCollection: isCollection,
                    isResolvable: true,
                    instanceComponents: instanceComponents
                ))
                continue
            }
            
            if let relationshipAttr = findAttribute(named: "StorableRelationship", in: varDecl.attributes),
               let info = analyzeRelationshipType(typeText) {
                let defType = mapRelatedType(info, suffix: "Definition")
                let instType = mapRelatedType(info, suffix: "Instance")

                var relArgs: [String] = []
                if let deleteRule = findArgument(labeled: "deleteRule", in: relationshipAttr) {
                    relArgs.append("deleteRule: \(deleteRule.expression.trimmedDescription)")
                }
                if let inverse = findArgument(labeled: "inverse", in: relationshipAttr) {
                    let rewritten = rewriteInverseKeyPathToDefinition(inverse.expression.trimmedDescription)
                    relArgs.append("inverse: \(rewritten)")
                }
                let relAttrText = relArgs.isEmpty ? "@Relationship" : "@Relationship(\(relArgs.joined(separator: ", ")))"

                defRelDecls.append("\(relAttrText)\n    var \(name): \(defType)")
                instRelDecls.append("var \(name): \(instType)")
                defRelInitParams.append("\(name): \(defType)")
                instRelInitParams.append("\(name): \(instType)")
                
                relations.append(.init(
                    name: name,
                    baseTypeName: info.base,
                    isCollection: info.container == .array || info.container == .set,
                    isResolvable: false,
                    instanceComponents: []
                ))
                continue
            }

            let markers = markersForAttributes(varDecl.attributes)
            if markers == .both {
                context.diagnose(Diagnostic(
                    node: Syntax(varDecl),
                    message: StorableMessage(id: "conflictingMarkers", message: "Property '\(name)' cannot be annotated with both @DefinitionStored and @InstanceStored.", severity: .error)
                ))
            }

            let inDef = markers == .definitionOnly
            let inInst = markers == .instanceOnly

            if inDef || inInst {
                 props.append(Prop(name: name, type: typeText, inDefinition: inDef, inInstance: inInst))
            }
        }

        let defProps = props.filter { $0.inDefinition }
        let instProps = props.filter { $0.inInstance }

        var decls: [DeclSyntax] = []
        decls.append(createBlockingUnavailableInit(baseName: baseName, propsInfo: allInitParams))
        decls.append(createDefinitionClass(defProps: defProps, relDecls: defRelDecls, relInitParams: defRelInitParams))
        decls.append(createInstanceClass(instProps: instProps, relDecls: instRelDecls, relInitParams: instRelInitParams))
        decls.append(createSourceEnum())
        decls.append(createResolvedStruct(props: props, relations: relations))
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
        @available(*, unavailable, message: "Do not instantiate \(raw: baseName) directly. Use generated nested types instead.")
        """
        return [attr]
    }

    // MARK: - Generation
    private static func createBlockingUnavailableInit(baseName: String, propsInfo: [(name: String, type: String)]) -> DeclSyntax {
        let params = propsInfo.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        return DeclSyntax(stringLiteral: """
        @available(*, unavailable, message: "Do not instantiate '\(baseName)'. Use generated nested types instead.")
        public init(\(params)) { fatalError("This initializer cannot be called.") }
        """)
    }

    private static func createDefinitionClass(defProps: [Prop], relDecls: [String], relInitParams: [String]) -> DeclSyntax {
        let propsBlock = defProps.map { "var \($0.name): \($0.type)" }.joined(separator: "\n\n    ")
        let relBlock = relDecls.joined(separator: "\n\n    ")
        let initParamsList = ["uuid: UUID = UUID()"] + defProps.map { "\($0.name): \($0.type)" } + relInitParams
        let initParams = initParamsList.joined(separator: ", ")
        func names(from params: [String]) -> [String] { params.compactMap { $0.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) } }
        let assignsLines = ["self.uuid = uuid"] + defProps.map { "self.\($0.name) = \($0.name)" } + names(from: relInitParams).map { "self.\($0) = \($0)" }
        let assigns = assignsLines.joined(separator: "\n        ")
        let bodyMembers = [propsBlock, relBlock].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        @Model public final class Definition {
            @Attribute(.unique) public var uuid: UUID
            \(raw: bodyMembers)
            public init(\(raw: initParams)) {
                \(raw: assigns)
            }
        }
        """)
    }

    private static func createInstanceClass(instProps: [Prop], relDecls: [String], relInitParams: [String]) -> DeclSyntax {
        let propsBlock = instProps.map { "var \($0.name): \($0.type)" }.joined(separator: "\n\n    ")
        let relBlock = relDecls.joined(separator: "\n\n    ")
        let initParamsList = ["id: UUID = UUID()", "definitionUUID: UUID"] + instProps.map { "\($0.name): \($0.type)" } + relInitParams
        let initParams = initParamsList.joined(separator: ", ")
        func names(from params: [String]) -> [String] { params.compactMap { $0.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) } }
        let assignsLines = ["self.id = id", "self.definitionUUID = definitionUUID"] + instProps.map { "self.\($0.name) = \($0.name)" } + names(from: relInitParams).map { "self.\($0) = \($0)" }
        let assigns = assignsLines.joined(separator: "\n        ")
        let bodyMembers = [propsBlock, relBlock].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n    ")
        return DeclSyntax("""
        @Observable public final class Instance: Codable, Hashable, Identifiable {
            public var id: UUID
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
    
    private static func createResolvedStruct(props: [Prop], relations: [RelationInfo]) -> DeclSyntax {
        let computedProps = props.map { p -> String in
            switch (p.inDefinition, p.inInstance) {
            case (true, false):
                return "public var \(p.name): \(p.type) { definition.\(p.name) }"
            case (false, true):
                return "public var \(p.name): \(p.type) { instance.\(p.name) }"
            default: return ""
            }
        }.joined(separator: "\n\n    ")
        
        let resolvedRelations = relations.map { rel -> String in
            let resolvedType = rel.isCollection ? "[\(rel.baseTypeName).Resolved]" : "\(rel.baseTypeName).Resolved"
            
            if rel.isResolvable {
                if rel.isCollection {
                    var resolverParams: [String] = []
                    resolverParams.append("definitions: definition.\(rel.name)")
                    if rel.instanceComponents.contains("Override") {
                        resolverParams.append("overrides: instance.\(rel.name)Overrides")
                    }
                    if rel.instanceComponents.contains("Instance") {
                        resolverParams.append("instances: instance.\(rel.name)Instances")
                    }
                    return """
                    public var \(rel.name): \(resolvedType) {
                        return \(rel.baseTypeName).Resolver.resolve(\(resolverParams.joined(separator: ", ")))
                    }
                    """
                } else {
                    var resolverParams: [String] = []
                    resolverParams.append("definition: definition.\(rel.name)")
                    if rel.instanceComponents.contains("Override") {
                        resolverParams.append("override: instance.\(rel.name)Override")
                    }
                    return """
                    public var \(rel.name): \(resolvedType) {
                        return \(rel.baseTypeName).Resolver.resolve(\(resolverParams.joined(separator: ", ")))
                    }
                    """
                }
            } else {
                if rel.isCollection {
                    return """
                    public var \(rel.name): \(resolvedType) {
                        let defs = definition.\(rel.name)
                        let insts = instance.\(rel.name)
                        return zip(defs, insts).map { (def, inst) in
                            \(rel.baseTypeName).Resolver.resolve(definition: def, instance: inst)
                        }
                    }
                    """
                } else {
                    return """
                    public var \(rel.name): \(resolvedType) {
                        return \(rel.baseTypeName).Resolver.resolve(definition: definition.\(rel.name), instance: instance.\(rel.name))
                    }
                    """
                }
            }
        }.joined(separator: "\n\n    ")

        return DeclSyntax("""
        public struct Resolved: Identifiable, Hashable {
            public var id: UUID { instance.id }
            public let source: Source
            public let definition: Definition
            public let instance: Instance

            \(raw: computedProps)
            
            \(raw: resolvedRelations)
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

    // MARK: - Attribute Parsing Helpers (Now inside the struct)
    private static func findAttribute(named name: String, in attributes: AttributeListSyntax?) -> AttributeSyntax? {
        guard let attributes else { return nil }
        return attributes.first(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name })?.as(AttributeSyntax.self)
    }

    private static func findArgument(labeled name: String, in attribute: AttributeSyntax) -> LabeledExprSyntax? {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        return args.first(where: { $0.label?.text == name })
    }

    private static func extractTypeName(from expr: ExprSyntax) -> String? {
        let text = expr.trimmedDescription
        if text.hasSuffix(".self") { return String(text.dropLast(5)) }
        return nil
    }

    private static func applyContainer(_ container: ContainerKind, to baseType: String) -> String {
        switch container {
        case .single: return baseType
        case .optional: return "\(baseType)?"
        case .array: return "[\(baseType)]"
        case .arrayOptional: return "[\(baseType)]?"
        case .set: return "Set<\(baseType)>"
        case .setOptional: return "Set<\(baseType)>?"
        }
    }

    private static func markersForAttributes(_ attributes: AttributeListSyntax?) -> MarkerUse {
        guard let attributes else { return .none }
        let hasDef = findAttribute(named: "DefinitionStored", in: attributes) != nil
        let hasInst = findAttribute(named: "InstanceStored", in: attributes) != nil
        switch (hasDef, hasInst) {
        case (false, false): return .none
        case (true, false):  return .definitionOnly
        case (false, true):  return .instanceOnly
        case (true, true):   return .both
        }
    }

    private static func analyzeRelationshipType(_ typeText: String) -> RelationshipTypeInfo? {
        var t = typeText.trimmingCharacters(in: .whitespacesAndNewlines)
        var opt = false
        if t.hasSuffix("?") { opt = true; t.removeLast(); t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    private static func mapRelatedType(_ info: RelationshipTypeInfo, suffix: String) -> String {
        let mappedBase = "\(info.base).\(suffix)"
        return applyContainer(info.container, to: mappedBase)
    }

    private static func rewriteInverseKeyPathToDefinition(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.first == "\\" else { return raw }
        if s.contains(".Definition.") { return s }
        let noSlash = String(s.dropFirst())
        var parts = noSlash.split(separator: ".").map(String.init)
        if let idx = parts.firstIndex(where: { $0.first?.isLowercase == true }) {
            if idx > 0 { parts.insert("Definition", at: idx) }
        } else {
            parts.append("Definition")
        }
        return "\\" + parts.joined(separator: ".")
    }
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
