import Foundation
import Resolvable

@Resolvable
struct Product {
    @Overridable var title: String
    var sku: String
    @Overridable var price: Decimal
    var isActive: Bool
}

func runDemo() {
    // Definitions (canonical)
    let mugID = UUID()
    let shirtID = UUID()

    let defs: [Product.Definition] = [
        .init(id: mugID,   title: "Coffee Mug", sku: "MUG-COFFEE-12OZ", price: 12.99, isActive: true),
        .init(id: shirtID, title: "T‑Shirt", sku: "TSHIRT-BLACK-M", price: 24.00, isActive: false)
    ]

    // Overrides (only for @Overridable fields: title, price)
    let ovs: [Product.Override] = [
        .init(definitionID: shirtID, title: "T‑Shirt (Promo)", price: 19.00)
    ]

    // Instances (ad‑hoc)
    let insts: [Product.Instance] = [
        .init(title: "Sticker Pack", sku: "STICKER-PACK", price: 4.50, isActive: true)
    ]

    // Resolve
    let resolved = Product.Resolver.resolve(definitions: defs, overrides: ovs, instances: insts)

    // Pretty print
    for r in resolved {
        let source: String = {
            switch r.source {
            case .definition(let id): return "definition(\(id))"
            case .instance(let id):   return "instance(\(id))"
            }
        }()
        print("Resolved [\(source)]: title=\(r.title), sku=\(r.sku), price=\(r.price), isActive=\(r.isActive)")
    }
}

runDemo()
