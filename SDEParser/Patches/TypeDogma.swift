//
//  TypeDogma.swift
//  SDEParser
//
//  Created by Oskar on 7/26/25.
//

import Foundation

enum TypeDogmaPatchError: Error {
    case unknownAttribute(String)
    case unknownEffect(String)
    case unknownCategory(String)
    case unknownType(String)
}

/// Fixes up an attribute entry, resolving name to attributeID.
func fixupAttribute(_ attribute: inout [String: Any], data: [String: Any]) throws {
    if let name = attribute["attribute"] as? String,
       let dogmaAttrs = data["dogmaAttributes"] as? [Int: [String: Any]],
       let id = dogmaAttrs.first(where: { $0.value["name"] as? String == name })?.key {
        attribute["attributeID"] = id
        attribute.removeValue(forKey: "attribute")
    } else {
        throw TypeDogmaPatchError.unknownAttribute(attribute["attribute"] as? String ?? "")
    }
}

/// Fixes up an effect entry, resolving name to effectID.
func fixupEffect(_ effect: inout [String: Any], data: [String: Any]) throws {
    if let name = effect["effect"] as? String,
       let dogmaEffs = data["dogmaEffects"] as? [Int: [String: Any]],
       let id = dogmaEffs.first(where: { $0.value["effectName"] as? String == name })?.key {
        effect["effectID"] = id
        effect.removeValue(forKey: "effect")
    } else {
        throw TypeDogmaPatchError.unknownEffect(effect["effect"] as? String ?? "")
    }
}

/// Applies type dogma patches to the entries dictionary.
func applyTypeDogmaPatches(
    to entries: inout [Int: [String: Any]],
    using patches: [[String: Any]],
    data: [String: Any]
) throws {
    for var patch in patches {
        // Lookup fields that require lookup.
        if var attrs = patch["dogmaAttributes"] as? [[String: Any]] {
            for i in attrs.indices {
                var attr = attrs[i]
                try fixupAttribute(&attr, data: data)
                attrs[i] = attr
            }
            patch["dogmaAttributes"] = attrs
        }
        if var effs = patch["dogmaEffects"] as? [[String: Any]] {
            for i in effs.indices {
                var eff = effs[i]
                try fixupEffect(&eff, data: data)
                effs[i] = eff
            }
            patch["dogmaEffects"] = effs
        }

        var appliedIDs = Set<Int>()

        // Fixup patch entries.
        if let targets = patch["patch"] as? [[String: Any]] {
            for target in targets {
                var typeIDs: [Int] = []
                if let categoryName = target["category"] as? String,
                   let categories = data["categories"] as? [Int: [String: Any]],
                   let categoryID = categories.first(where: { $0.value["name"] as? String == categoryName })?.key,
                   let groups = data["groups"] as? [Int: [String: Any]],
                   let types = data["types"] as? [Int: [String: Any]] {
                    // category filter
                    let groupIDs = groups.filter { $0.value["categoryID"] as? Int == categoryID }.map { $0.key }
                    typeIDs = types.filter { groupIDs.contains($0.value["groupID"] as? Int ?? -1) }.map { $0.key }
                } else if let typeName = target["type"] as? String,
                          let types = data["types"] as? [Int: [String: Any]] {
                    // type filter
                    typeIDs = types.filter { $0.value["name"] as? String == typeName }.map { $0.key }
                } else {
                    throw TypeDogmaPatchError.unknownCategory(target["category"] as? String ?? "")
                }

                // Ensure there is a dogma entry for each type.
                for typeID in typeIDs {
                    if entries[typeID] == nil {
                        entries[typeID] = [
                            "dogmaAttributes": [],
                            "dogmaEffects": []
                        ]
                    }
                }

                // hasAllAttributes filter
                if let hasAll = target["hasAllAttributes"] as? [[String: Any]],
                   let _ = data["dogmaAttributes"] as? [Int: [String: Any]] {
                    var filteredIDs: [Int] = []
                    for var attrPrereq in hasAll {
                        try fixupAttribute(&attrPrereq, data: data)
                        let prereqID = attrPrereq["attributeID"] as! Int
                        for typeID in typeIDs where
                            (entries[typeID]?["dogmaAttributes"] as? [[String: Any]] ?? [])
                                .contains(where: { ($0["attributeID"] as? Int) == prereqID })
                        {
                            filteredIDs.append(typeID)
                        }
                    }
                    typeIDs = filteredIDs
                }

                // hasAnyAttributes filter
                if let hasAny = target["hasAnyAttributes"] as? [[String: Any]] {
                    var filteredIDs: [Int] = []
                    for var attrPrereq in hasAny {
                        try fixupAttribute(&attrPrereq, data: data)
                        let prereqID = attrPrereq["attributeID"] as! Int
                        for typeID in typeIDs where
                            (entries[typeID]?["dogmaAttributes"] as? [[String: Any]] ?? [])
                                .contains(where: { ($0["attributeID"] as? Int) == prereqID })
                        {
                            filteredIDs.append(typeID)
                        }
                    }
                    typeIDs = filteredIDs
                }

                // hasAnyEffects filter
                if let hasEffs = target["hasAnyEffects"] as? [[String: Any]] {
                    var filteredIDs: [Int] = []
                    for var effPrereq in hasEffs {
                        try fixupEffect(&effPrereq, data: data)
                        let prereqID = effPrereq["effectID"] as! Int
                        for typeID in typeIDs where
                            (entries[typeID]?["dogmaEffects"] as? [[String: Any]] ?? [])
                                .contains(where: { ($0["effectID"] as? Int) == prereqID })
                        {
                            filteredIDs.append(typeID)
                        }
                    }
                    typeIDs = filteredIDs
                }

                // Ensure we never apply the same patch twice on the same type.
                typeIDs = Array(Set(typeIDs).subtracting(appliedIDs))

                // Append attributes and effects
                if let toAddAttrs = patch["dogmaAttributes"] as? [[String: Any]] {
                    for typeID in typeIDs {
                        var entry = entries[typeID]!
                        var list = entry["dogmaAttributes"] as? [[String: Any]] ?? []
                        list.append(contentsOf: toAddAttrs)
                        entry["dogmaAttributes"] = list
                        entries[typeID] = entry
                    }
                }
                if let toAddEffs = patch["dogmaEffects"] as? [[String: Any]] {
                    for typeID in typeIDs {
                        var entry = entries[typeID]!
                        var list = entry["dogmaEffects"] as? [[String: Any]] ?? []
                        list.append(contentsOf: toAddEffs)
                        entry["dogmaEffects"] = list
                        entries[typeID] = entry
                    }
                }

                appliedIDs.formUnion(typeIDs)
            }
        }
    }
}
