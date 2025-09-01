import Foundation
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct DefinitionSourceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Pure marker; generate no code.
        return []
    }
}

public struct ResolvableDestinationMacro: MemberMacro, ExtensionMacro {

    // MARK: - Extension role: add empty conformance
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(ActorDeclSyntax.self) else {
            return []
        }
        let decl: DeclSyntax = "extension \(type.trimmed): ResolvableBacked {}"
        return [decl.as(ExtensionDeclSyntax.self)!]
    }

    // MARK: - Member role
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(ActorDeclSyntax.self) else {
            return []
        }

        // @ResolvableDestination(for: Model.self)
        guard let modelType = parseModelType(from: node) else {
            emitError(context, node: Syntax(node), message: "Expected 'for: <Type>.self' argument")
            return []
        }
        let modelTypeText = modelType.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let members = declaration.memberBlock.members

        // Build expression for definitions
        let defExpr = findDefinitionSourceExpr(members: members, modelTypeText: modelTypeText)

        // Find [Model.Override] backing
        let overridesBacking = findStorageArray(members: members) { elem in
            normalized(elem.description) == normalized("\(modelTypeText).Override")
        }

        // Find [Model.Instance] backing
        let instancesBacking = findStorageArray(members: members) { elem in
            normalized(elem.description) == normalized("\(modelTypeText).Instance")
        }

        var decls: [DeclSyntax] = []
        decls.append("public typealias ResolvableType = \(raw: modelTypeText)")

        if let defExpr {
            decls.append("""
            public var definitions: [\(raw: modelTypeText).Definition] {
                \(raw: defExpr)
            }
            """)
        } else {
            emitError(context, node: Syntax(node), message: "No @DefinitionSource found for [\(modelTypeText).Definition]")
        }

        if let ov = overridesBacking {
            decls.append("""
            public var overrides: [\(raw: modelTypeText).Override] {
                get { \(raw: ov) }
                set { \(raw: ov) = newValue }
            }
            """)
        } else {
            emitError(context, node: Syntax(node), message: "No stored property of type [\(modelTypeText).Override] found")
        }

        if let inst = instancesBacking {
            decls.append("""
            public var instances: [\(raw: modelTypeText).Instance] {
                get { \(raw: inst) }
                set { \(raw: inst) = newValue }
            }
            """)
        } else {
            emitError(context, node: Syntax(node), message: "No stored property of type [\(modelTypeText).Instance] found")
        }

        // Synthesize no-op markAsChanged() if absent
        let hasMark = members.contains { m in
            guard let f = m.decl.as(FunctionDeclSyntax.self) else { return false }
            return f.name.text == "markAsChanged" && f.signature.parameterClause.parameters.isEmpty
        }
        if !hasMark {
            decls.append("public func markAsChanged() {}")
        }

        return decls
    }

    // MARK: Parsing helpers

    private static func parseModelType(from node: AttributeSyntax) -> TypeSyntax? {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let arg = args.first(where: { $0.label?.text == "for" })
        else { return nil }
        let text = arg.expression.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if text.hasSuffix(".self") {
            return TypeSyntax(stringLiteral: String(text.dropLast(5)))
        }
        return TypeSyntax(stringLiteral: text)
    }

    // Build an expression to read [Model.Definition]
    // Examples:
    // - self.definition?.propertyDefinitions ?? []
    // - self.productDefinitions
    // - self.nonOptional.propertyDefinitions
    private static func findDefinitionSourceExpr(
        members: MemberBlockItemListSyntax,
        modelTypeText: String
    ) -> String? {

        // Prefer properties explicitly annotated with @DefinitionSource(for:)
        for m in members {
            guard let v = m.decl.as(VariableDeclSyntax.self),
                  let binding = v.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { continue }

            guard let attr = v.attributes.compactMap({ $0.as(AttributeSyntax.self) })
                .first(where: { $0.attributeName.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "DefinitionSource" })
            else { continue }

            if let forType = typeArg(from: attr, label: "for") {
                guard normalized(forType.description) == normalized(modelTypeText) else { continue }

                if let leaf = keyPathLastLeaf(from: attr, label: "at") {
                    let isOpt = binding.typeAnnotation.map { isOptionalType($0.type) } ?? false
                    let base = "self.\(name)"
                    return isOpt ? "\(base)?.\(leaf) ?? []" : "\(base).\(leaf)"
                }

                // If wrapper is on [Model.Definition] itself
                if let ty = binding.typeAnnotation?.type,
                   let elem = elementTypeIfArray(ty),
                   normalized(elem.description) == normalized("\(modelTypeText).Definition") {
                    return "self.\(name)"
                }
            }
        }

        // Next: any @DefinitionSource whose element is [Model.Definition]
        for m in members {
            guard let v = m.decl.as(VariableDeclSyntax.self),
                  let binding = v.bindings.first,
                  binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let ty = binding.typeAnnotation?.type,
                  let elem = elementTypeIfArray(ty)
            else { continue }

            let hasMarker = v.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "DefinitionSource"
            }
            guard hasMarker else { continue }

            if normalized(elem.description) == normalized("\(modelTypeText).Definition") {
                return "self.\(name)"
            }
        }

        // Fallback: any stored [Model.Definition]
        for m in members {
            guard let v = m.decl.as(VariableDeclSyntax.self),
                  let binding = v.bindings.first,
                  binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let ty = binding.typeAnnotation?.type,
                  let elem = elementTypeIfArray(ty)
            else { continue }
            if normalized(elem.description) == normalized("\(modelTypeText).Definition") {
                return "self.\(name)"
            }
        }

        return nil
    }

    private static func typeArg(from attr: AttributeSyntax, label: String) -> TypeSyntax? {
        guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
              let match = args.first(where: { $0.label?.text == label })
        else { return nil }
        let text = match.expression.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if text.hasSuffix(".self") {
            return TypeSyntax(stringLiteral: String(text.dropLast(5)))
        }
        return TypeSyntax(stringLiteral: text)
    }

    private static func keyPathLastLeaf(from attr: AttributeSyntax, label: String) -> String? {
        guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
              let match = args.first(where: { $0.label?.text == label }),
              let kp = match.expression.as(KeyPathExprSyntax.self)
        else { return nil }
        return kp.components.last?.component
            .as(KeyPathPropertyComponentSyntax.self)?
            .declName.baseName.text
    }

    // Stored var of [T] or Array<T>
    private static func findStorageArray(
        members: MemberBlockItemListSyntax,
        elementMatches: (TypeSyntax) -> Bool
    ) -> String? {
        for m in members {
            guard let v = m.decl.as(VariableDeclSyntax.self),
                  let binding = v.bindings.first,
                  binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let ty = binding.typeAnnotation?.type,
                  let elem = elementTypeIfArray(ty),
                  elementMatches(elem)
            else { continue }
            return name
        }
        return nil
    }

    private static func elementTypeIfArray(_ type: TypeSyntax) -> TypeSyntax? {
        if let arr = type.as(ArrayTypeSyntax.self) {
            return arr.element
        }
        if let ident = type.as(IdentifierTypeSyntax.self),
           ident.name.text == "Array",
           let firstArg = ident.genericArgumentClause?.arguments.first?.argument {
            return firstArg
        }
        return nil
    }

    private static func isOptionalType(_ type: TypeSyntax) -> Bool {
        if type.is(OptionalTypeSyntax.self) { return true }
        if let ident = type.as(IdentifierTypeSyntax.self), ident.name.text == "Optional" { return true }
        return type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).hasSuffix("?")
    }

    private static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
         .replacingOccurrences(of: "\n", with: "")
    }

    // Diagnostics
    private static func emitError(_ context: some MacroExpansionContext, node: Syntax, message: String) {
        context.diagnose(Diagnostic(node: node, message: SimpleMessage(id: "ResolvableDestination.error", message: message, severity: .error)))
    }
}

private struct SimpleMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    init(id: String, message: String, severity: DiagnosticSeverity) {
        self.message = message
        self.diagnosticID = MessageID(domain: "ResolvableDestination", id: id)
        self.severity = severity
    }
}
