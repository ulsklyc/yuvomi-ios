// Handgeschrieben statt generiert, siehe typeOverrides in openapi-generator-config.yaml.
// Felder wie Components.Schemas.ShoppingItemUpdateInput in Spec/openapi.json.

/// Body von `PATCH /shopping/items/{itemId}`. Was fehlt, bleibt wie gespeichert.
///
/// Felder, die `null` annehmen, sind ein `Patch`; die übrigen werden bei `nil` weggelassen.
struct ShoppingItemUpdateInput: Codable, Hashable, Sendable {
    var isChecked: Bool? = nil
    var name: String? = nil
    var quantity: Patch<String> = .unset
    var category: String? = nil
    var notes: Patch<String> = .unset
    var url: Patch<String> = .unset
    var priceCents: Patch<Int> = .unset
    var storeId: Patch<Int> = .unset
    var listId: Patch<Int> = .unset

    enum CodingKeys: String, CodingKey {
        case isChecked = "is_checked"
        case name
        case quantity
        case category
        case notes
        case url
        case priceCents = "price_cents"
        case storeId = "store_id"
        case listId = "list_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isChecked, forKey: .isChecked)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encode(notes, forKey: .notes)
        try container.encode(url, forKey: .url)
        try container.encode(priceCents, forKey: .priceCents)
        try container.encode(storeId, forKey: .storeId)
        try container.encode(listId, forKey: .listId)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        quantity = try container.decode(Patch<String>.self, forKey: .quantity)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        notes = try container.decode(Patch<String>.self, forKey: .notes)
        url = try container.decode(Patch<String>.self, forKey: .url)
        priceCents = try container.decode(Patch<Int>.self, forKey: .priceCents)
        storeId = try container.decode(Patch<Int>.self, forKey: .storeId)
        listId = try container.decode(Patch<Int>.self, forKey: .listId)
    }
}

extension ShoppingItemUpdateInput {
    init(
        isChecked: Bool? = nil,
        name: String? = nil,
        quantity: Patch<String> = .unset,
        category: String? = nil,
        notes: Patch<String> = .unset,
        url: Patch<String> = .unset,
        priceCents: Patch<Int> = .unset,
        storeId: Patch<Int> = .unset,
        listId: Patch<Int> = .unset
    ) {
        self.isChecked = isChecked
        self.name = name
        self.quantity = quantity
        self.category = category
        self.notes = notes
        self.url = url
        self.priceCents = priceCents
        self.storeId = storeId
        self.listId = listId
    }
}
