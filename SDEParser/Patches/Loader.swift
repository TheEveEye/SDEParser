//
//  Loader.swift
//  SDEParser
//
//  Created by Oskar on 7/26/25.
//


import Foundation
import Yams

/// Loads patch files from the "patches" directory and collects entries.
/// - Returns: A dictionary with keys "effects", "attributes", and "typeDogma", each mapping to an array of entry dictionaries.
func loadPatches(at path: URL) throws -> [String: Any] {
    let fileManager = FileManager.default
    // Use the provided path as the patches directory
    let patchesDir = path
    let fileURLs = try fileManager.contentsOfDirectory(at: patchesDir,
                                                       includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "yaml" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var effects: [[String: Any]] = []
    var attributes: [[String: Any]] = []
    var typeDogma: [[String: Any]] = []

    for fileURL in fileURLs {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let patch = try Yams.load(yaml: text) as? [String: Any] else { continue }

        if let attrs = patch["attributes"] as? [[String: Any]] {
            attributes.append(contentsOf: attrs)
        }
        if let effs = patch["effects"] as? [[String: Any]] {
            effects.append(contentsOf: effs)
        }
        if let td = patch["typeDogma"] as? [[String: Any]] {
            typeDogma.append(contentsOf: td)
        }
    }
    return [
        "effects": effects,
        "attributes": attributes,
        "typeDogma": typeDogma
    ]
}
