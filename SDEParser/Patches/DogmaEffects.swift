//
//  DogmaEffects.swift
//  SDEParser
//
//  Created by Oskar on 7/26/25.
//

import Foundation

enum DogmaEffectsPatchError: Error {
    case unknownAttribute(String)
    case unknownSkill(String)
    case duplicateEffectName(String)
}

// Mappings from names to IDs
let effectCategoryNameToId: [String: Int] = [
    "passive": 0, "active": 1, "target": 2, "area": 3,
    "online": 4, "overload": 5, "dungeon": 6, "system": 7
]

let effectOperationNameToId: [String: Int] = [
    "preAssign": -1, "preMul": 0, "preDiv": 1, "modAdd": 2,
    "modSub": 3, "postMul": 4, "postDiv": 5, "postPercent": 6,
    "postAssign": 7
]

/// Fixes up a single modifier dictionary, resolving names to IDs.
func fixupModifierInfo(_ modifier: inout [String: Any], data: [String: Any]) throws {

    // Resolve modifiedAttribute -> modifiedAttributeID
    if let name = modifier["modifiedAttribute"] as? String,
       let dogmaAttrs = data["dogmaAttributes"] as? [Int: [String: Any]] {
        if let id = dogmaAttrs.first(where: { $0.value["name"] as? String == name })?.key {
            modifier["modifiedAttributeID"] = id
            modifier.removeValue(forKey: "modifiedAttribute")
        } else {
            throw DogmaEffectsPatchError.unknownAttribute(name)
        }
    }
    // Resolve modifyingAttribute -> modifyingAttributeID
    if let name = modifier["modifyingAttribute"] as? String,
       let dogmaAttrs = data["dogmaAttributes"] as? [Int: [String: Any]] {
        if let id = dogmaAttrs.first(where: { $0.value["name"] as? String == name })?.key {
            modifier["modifyingAttributeID"] = id
            modifier.removeValue(forKey: "modifyingAttribute")
        } else {
            throw DogmaEffectsPatchError.unknownAttribute(name)
        }
    }
    // Resolve skillType -> skillTypeID
    if let skill = modifier["skillType"] as? String {
        if skill == "IfSkillRequired" {
            modifier["skillTypeID"] = -1
        } else {
            guard let types = data["types"] as? [Int: [String: Any]] else {
                throw DogmaEffectsPatchError.unknownSkill("No types dictionary in data while resolving skill: \(skill)")
            }
            if let id = types.first(where: { $0.value["name"] as? String == skill })?.key {
                modifier["skillTypeID"] = id
            } else {
                throw DogmaEffectsPatchError.unknownSkill(skill)
            }
        }
        modifier.removeValue(forKey: "skillType")
    }
    // Map operation name -> operation ID
    if let opName = modifier["operation"] as? String,
       let opId = effectOperationNameToId[opName] {
        modifier["operation"] = opId
    }
}

/// Applies patches to the dogma effects entries dictionary.
/// - Parameters:
///   - entries: A mapping from effect IDs to entry dictionaries.
///   - patches: An array of patch dictionaries.
///   - data: The full data context (e.g., includes "dogmaAttributes" and "types").
/// - Throws: Various errors if lookups fail or effect names collide.
func applyDogmaEffectPatches(
    to entries: inout [Int: [String: Any]],
    using patches: [[String: Any]],
    data: [String: Any]
) throws {
    var nextEffectID = -1
    for var patch in patches {
        // Convert effectCategory name to ID
        if let catName = patch["effectCategory"] as? String,
           let catId = effectCategoryNameToId[catName] {
            patch["effectCategory"] = catId
        }

        // Fix up any nested modifierInfo
        if var mods = patch["modifierInfo"] as? [[String: Any]] {
            for i in mods.indices {
                try fixupModifierInfo(&mods[i], data: data)
            }
            patch["modifierInfo"] = mods
        }

        // Handle new entries
        if let newInfo = patch["new"] as? [String: Any] {
            // Set the effectName
            if let newName = newInfo["name"] as? String {
                patch["effectName"] = newName
            }
            // Determine ID
            let id: Int
            if let explicit = newInfo["id"] as? Int {
                id = explicit
            } else {
                id = nextEffectID
            }
            patch.removeValue(forKey: "new")
            // Ensure unique name
            for entry in entries.values {
                if let existing = entry["effectName"] as? String,
                   existing == (patch["effectName"] as? String ?? "") {
                    throw DogmaEffectsPatchError.duplicateEffectName(existing)
                }
            }
            entries[id] = patch
            nextEffectID -= 1
        }

        // Handle patches to existing entries
        if let targets = patch["patch"] as? [[String: Any]] {
            let names = targets.compactMap { $0["name"] as? String }
            let effectIDs = entries.compactMap { (key, entry) -> Int? in
                if let name = entry["effectName"] as? String, names.contains(name) {
                    return key
                }
                return nil
            }
            // Append modifierInfo to targets
            if let mods = patch["modifierInfo"] as? [[String: Any]] {
                for effectID in effectIDs {
                    var entry = entries[effectID]!
                    var existingMods = entry["modifierInfo"] as? [[String: Any]] ?? []
                    existingMods.append(contentsOf: mods)
                    entry["modifierInfo"] = existingMods
                    entries[effectID] = entry
                }
            }
            // Remove patch markers
            patch.removeValue(forKey: "patch")
            patch.removeValue(forKey: "modifierInfo")
            // Update other fields
            for effectID in effectIDs {
                var entry = entries[effectID]!
                for (k,v) in patch {
                    entry[k] = v
                }
                entries[effectID] = entry
            }
        }
    }
}

