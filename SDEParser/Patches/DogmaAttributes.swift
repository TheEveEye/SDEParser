//
//  DogmaAttributes.swift
//  SDEParser
//
//  Created by Oskar on 7/26/25.
//

import Foundation

enum DogmaAttributePatchError: Error {
    case duplicateAttributeName(String)
}

/// Applies patches to the dogma attributes entries dictionary.
/// - Parameters:
///   - entries: A dictionary mapping attribute IDs to entry dictionaries.
///   - patches: An array of patch dictionaries, each potentially containing a "new" key.
/// - Throws: `DogmaAttributePatchError.duplicateAttributeName` if a new attribute name is not unique.
func applyDogmaAttributePatches(
    to entries: inout [Int: [String: Any]],
    using patches: [[String: Any]]
) throws {
    var nextAttributeID = -1

    for var patch in patches {
        if let newInfo = patch["new"] as? [String: Any] {
            // Take the new name
            guard let newName = newInfo["name"] as? String else { continue }
            patch["name"] = newName

            // Determine ID: explicit or fallback to nextAttributeID
            let id: Int
            if let explicitID = newInfo["id"] as? Int {
                id = explicitID
            } else {
                id = nextAttributeID
            }

            // Remove the "new" key
            patch.removeValue(forKey: "new")

            // Ensure uniqueness
            for existing in entries.values {
                if let existingName = existing["name"] as? String, existingName == newName {
                    throw DogmaAttributePatchError.duplicateAttributeName(newName)
                }
            }

            // Insert the patched entry
            entries[id] = patch
            nextAttributeID -= 1
        }
    }
}
