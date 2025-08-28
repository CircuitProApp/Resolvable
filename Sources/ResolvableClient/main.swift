import Foundation
import Resolvable

@Resolvable
struct Product {
    @Overridable var title: String
    var sku: String
    @Overridable var price: Decimal = 10.0
    var isActive: Bool

    @Overridable(\Shipping.carrier, as: String.self) var shipping: Shipping
}

struct Shipping: Codable, Hashable, Equatable {
    var weight: Double
    var carrier: String
}

func runDemo() {
    let mugID = UUID()
    let shirtID = UUID()
    
    
    let defs: [Product.Definition] = [
        .init(id: mugID,
              title: "Coffee Mug",
              sku: "MUG-COFFEE-12OZ",
              price: 12.99,
              isActive: true,
              shipping: .init(weight: 0.4, carrier: "UPS")),
        .init(id: shirtID,
              title: "T‑Shirt",
              sku: "TSHIRT-BLACK-M",
              price: 24.00,
              isActive: false,
              shipping: .init(weight: 0.2, carrier: "FedEx"))
    ]
    
    // Overrides (title + price + nested shipping.carrier only)
    let ovs: [Product.Override] = [
        .init(definitionID: shirtID,
              title: "T‑Shirt (Promo)",
              price: 19.00,
              shipping_carrier: "DHL")
    ]
    
    // Instances (must specify full nested struct values)
    let insts: [Product.Instance] = [
        .init(title: "Sticker Pack",
              sku: "STICKER-PACK",
              price: 4.50,
              isActive: true,
              shipping: .init(weight: 0.05, carrier: "USPS"))
    ]
    
    let resolved = Product.Resolver.resolve(definitions: defs,
                                            overrides: ovs,
                                            instances: insts)
    
    for r in resolved {
        let source: String = {
            switch r.source {
            case .definition(let id): return "definition(\(id))"
            case .instance(let id):   return "instance(\(id))"
            }
        }()
        print("Resolved [\(source)]: title=\(r.title), sku=\(r.sku), price=\(r.price), " +
              "isActive=\(r.isActive), shipping=(weight=\(r.shipping.weight), carrier=\(r.shipping.carrier))")
    }
}

runDemo()
