// Sources/StorableClient/main.swift

import Foundation
import Storable

@Storable
struct Product {
    @DefinitionStored var title: String
    var sku: String
    var price: Decimal
    var isActive: Bool
    @StorableRelationship
    var type: ProductType
    @InstanceStored var localNotes: String
}

@Storable
struct ProductType {
    var name: String
}

func demo() {
    let defs: [Product.Definition] = [
        .init(uuid: UUID(), title: "Coffee Mug", sku: "MUG-12", price: 12.99, isActive: true, type: .init(uuid: .init(), name: "hello")),
        .init(uuid: UUID(), title: "T-Shirt", sku: "TSHIRT-BLK-M", price: 24.00, isActive: false, type: .init(uuid: .init(), name: "hewoo"))
    ]

    let insts: [Product.Instance] = defs.map { def in
    let inst = Product.Instance(      id: UUID(),
                                      definitionUUID: def.uuid,
                                      sku: def.sku,
                                      price: def.price,
                                      isActive: def.isActive,
                                      localNotes: "Requested for size medium", type: .init(definitionUUID: .init(), name: "jello"))
  
        
        return inst
    }

    let resolved = Product.Resolver.resolve(definitions: defs, instances: insts)
    for r in resolved {
        print("Resolved: \(r.title) – \(r.sku) – \(r.price) – active=\(r.isActive)")
    }
}

demo()
