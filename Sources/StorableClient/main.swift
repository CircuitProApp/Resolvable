// Sources/StorableClient/main.swift

import Foundation
import Storable

// With the current Storable macro:
// - Properties must be explicitly marked to be generated.
// - @DefinitionStored -> lives in Definition
// - @InstanceStored   -> lives in Instance
// - Unmarked props are NOT generated.

@Storable
struct Product {
    @DefinitionStored var title: String
    @DefinitionStored var sku: String
    @DefinitionStored var price: Decimal
    @DefinitionStored var isActive: Bool

    @StorableRelationship
    var type: ProductType

    @InstanceStored var localNotes: String
}

@Storable
struct ProductType {
    @DefinitionStored var name: String
}

func demo() throws {
    print("--- 1) Library Definitions ---")

    // Build type definitions
    let typeDef1 = ProductType.Definition(uuid: UUID(), name: "Kitchenware")
    let typeDef2 = ProductType.Definition(uuid: UUID(), name: "Apparel")

    // Build product definitions
    let productDefs: [Product.Definition] = [
        .init(
            uuid: UUID(),
            title: "Coffee Mug",
            sku: "MUG-12",
            price: 12.99,
            isActive: true,
            type: typeDef1
        ),
        .init(
            uuid: UUID(),
            title: "T-Shirt",
            sku: "TSHIRT-BLK-M",
            price: 24.00,
            isActive: false,
            type: typeDef2
        )
    ]
    print("Library: \(productDefs.count) Product defs")

    print("\n--- 2) Document Instances (hydrate-on-init) ---")
    // Build type instances with their definitions
    let typeInst1 = ProductType.Instance(definition: typeDef1)
    let typeInst2 = ProductType.Instance(definition: typeDef2)

    // Build product instances with their definitions
    // Note: Instance expects only @InstanceStored and relationship instance params.
    let productInsts: [Product.Instance] = [
        .init(
            definition: productDefs[0],
            localNotes: "Handle with care", type: typeInst1
        ),
        .init(
            definition: productDefs[1],
            localNotes: "Requested for size large", type: typeInst2
        )
    ]
    print("Document: \(productInsts.count) Product instances")

    print("\n--- 3) Access via hydrated definitions ---")
    for p in productInsts {
        let title   = p.definition?.title ?? "<unhydrated>"
        let sku     = p.definition?.sku ?? "<unhydrated>"
        let price   = p.definition?.price ?? 0
        let active  = p.definition?.isActive ?? false
        let typeStr = p.type.definition?.name ?? "<unhydrated>"

        print("Product: \(title) [Type: \(typeStr)] | SKU: \(sku) | Price: \(price) | Active: \(active) | Notes: \(p.localNotes)")
    }

    print("\n--- 4) Round-trip encode/decode, then rehydrate ---")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(productInsts)
    print(String(data: data, encoding: .utf8) ?? "")

    let decoder = JSONDecoder()
    let decoded = try decoder.decode([Product.Instance].self, from: data)

    // Build lookup maps to rehydrate definitions
    let productDefByUUID: [UUID: Product.Definition] =
        Dictionary(uniqueKeysWithValues: productDefs.map { ($0.uuid, $0) })
    let typeDefByUUID: [UUID: ProductType.Definition] =
        Dictionary(uniqueKeysWithValues: [typeDef1, typeDef2].map { ($0.uuid, $0) })

    // Rehydrate
    for p in decoded {
        p.definition = productDefByUUID[p.definitionUUID]
        p.type.definition = typeDefByUUID[p.type.definitionUUID]
    }

    print("\n--- 5) Use decoded + rehydrated instances ---")
    for p in decoded {
        let title   = p.definition?.title ?? "<unhydrated>"
        let sku     = p.definition?.sku ?? "<unhydrated>"
        let price   = p.definition?.price ?? 0
        let active  = p.definition?.isActive ?? false
        let typeStr = p.type.definition?.name ?? "<unhydrated>"

        print("Decoded Product: \(title) [Type: \(typeStr)] | SKU: \(sku) | Price: \(price) | Active: \(active) | Notes: \(p.localNotes)")
    }
}

// Run
try! demo()
