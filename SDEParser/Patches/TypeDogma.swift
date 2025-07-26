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
    if let name = attribute["attribute"] as? String {
        if let dogmaAttrs = data["dogmaAttributes"] as? [String: Any] {
            // Find attribute by name in YAML data structure (keys are strings)
            if let (idStr, attrData) = dogmaAttrs.first(where: { _, value in
                (value as? [String: Any])?["name"] as? String == name
            }), let id = Int(idStr) {
                attribute["attributeID"] = id
                attribute.removeValue(forKey: "attribute")
            } else {
                throw TypeDogmaPatchError.unknownAttribute(name)
            }
        } else {
            throw TypeDogmaPatchError.unknownAttribute(name)
        }
    } else {
        throw TypeDogmaPatchError.unknownAttribute(attribute["attribute"] as? String ?? "")
    }
}

/// Fixes up an effect entry, resolving name to effectID.
func fixupEffect(_ effect: inout [String: Any], data: [String: Any]) throws {
    if let name = effect["effect"] as? String {
        if let dogmaEffs = data["dogmaEffects"] as? [String: Any] {
            // Find effect by name in YAML data structure (keys are strings)
            if let (idStr, effData) = dogmaEffs.first(where: { _, value in
                (value as? [String: Any])?["effectName"] as? String == name
            }), let id = Int(idStr) {
                effect["effectID"] = id
                effect.removeValue(forKey: "effect")
            } else {
                throw TypeDogmaPatchError.unknownEffect(name)
            }
        } else {
            throw TypeDogmaPatchError.unknownEffect(name)
        }
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
                if let categoryName = target["category"] as? String {
                    // Handle YAML data structure with string keys
                    if let categories = data["categories"] as? [String: Any],
                       let categoryEntry = categories.first(where: { _, value in
                           (value as? [String: Any])?["name"] as? String == categoryName
                       }),
                       let categoryID = Int(categoryEntry.key),
                       let groups = data["groups"] as? [String: Any],
                       let types = data["types"] as? [String: Any] {
                        // category filter
                        let groupIDs = groups.compactMap { (key, value) -> Int? in
                            guard let groupData = value as? [String: Any],
                                  groupData["categoryID"] as? Int == categoryID,
                                  let groupID = Int(key) else { return nil }
                            return groupID
                        }
                        typeIDs = types.compactMap { (key, value) -> Int? in
                            guard let typeData = value as? [String: Any],
                                  let groupID = typeData["groupID"] as? Int,
                                  groupIDs.contains(groupID),
                                  let typeID = Int(key) else { return nil }
                            return typeID
                        }
                    } else {
                        throw TypeDogmaPatchError.unknownCategory(categoryName)
                    }
                } else if let typeName = target["type"] as? String {
                    // type filter with YAML data structure
                    if let types = data["types"] as? [String: Any] {
                        typeIDs = types.compactMap { (key, value) -> Int? in
                            guard let typeData = value as? [String: Any],
                                  typeData["name"] as? String == typeName,
                                  let typeID = Int(key) else { return nil }
                            return typeID
                        }
                    } else {
                        throw TypeDogmaPatchError.unknownType(typeName)
                    }
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
