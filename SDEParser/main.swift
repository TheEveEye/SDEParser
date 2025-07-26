import Foundation
import Yams

let fileManager = FileManager.default

let projectRoot = URL(fileURLWithPath: #file)
    .deletingLastPathComponent() // main.swift

let resourcesRoot = projectRoot.appendingPathComponent("Resources")

// Specify which YAML files (by filename) to process. Leave empty to process all.
let yamlFilesToProcess: [String] = [
    "categories",
    "dogmaAttributes",
    "dogmaEffects",
    "iconIDs",
    "groups",
    "marketGroups",
    "metaGroups",
    "typeDogma",
    "types",
]
// Option to clear the JSON output folder before processing

let clearDestinationFirst: Bool = true

// Load patch definitions
let patches: [String: Any] = {
    do {
        return try loadPatches(at: resourcesRoot.appendingPathComponent("patches"))
    } catch {
        print("⚠️ Failed to load patches: \(error)")
        return [:]
    }
}()

func processYAMLFiles(in directory: URL) {
    if clearDestinationFirst {
        let jsonDestinationRoot = resourcesRoot.appendingPathComponent("sde-json")
        try? fileManager.removeItem(at: jsonDestinationRoot)
        try? fileManager.createDirectory(at: jsonDestinationRoot, withIntermediateDirectories: true)
    }
    let startTime = Date()

    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        print("❌ Failed to enumerate directory: \(directory.path)")
        return
    }

    var yamlFiles: [URL] = []
    for case let fileURL as URL in enumerator {
        if fileURL.pathExtension == "yaml" {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            if yamlFilesToProcess.isEmpty || yamlFilesToProcess.contains(baseName) {
                yamlFiles.append(fileURL)
            }
        }
    }
    enumerator.skipDescendants()

    // Load all YAML data first for cross-references
    var allYamlData: [String: Any] = [:]
    print("🔄 Loading all YAML files for cross-references...")
    
    for fileURL in yamlFiles {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        do {
            let yamlString = try String(contentsOf: fileURL, encoding: .utf8)
            if let yamlData = try Yams.load(yaml: yamlString) {
                allYamlData[baseName] = yamlData
                print("📋 Pre-loaded \(baseName).yaml")
            }
        } catch {
            print("⚠️ Failed to pre-load \(baseName).yaml: \(error)")
        }
    }

    let totalFiles = yamlFiles.count
    var completedFiles = 0
    let progressQueue = DispatchQueue(label: "progress.queue")

    let group = DispatchGroup()
    let queue = DispatchQueue(label: "yaml.processing.queue", attributes: .concurrent)

    for fileURL in yamlFiles {
        group.enter()
        queue.async {
            defer {
                progressQueue.sync {
                    completedFiles += 1
                    print("📦 \(completedFiles)/\(totalFiles) | Converted \(fileURL.lastPathComponent) → \(fileURL.deletingPathExtension().appendingPathExtension("json").lastPathComponent)")
                }
                group.leave()
            }

            do {
                let baseName = fileURL.deletingPathExtension().lastPathComponent
                guard var finalData = allYamlData[baseName] else {
                    print("⚠️ Skipping: No pre-loaded data for \(baseName)")
                    return
                }

                // Apply patches for dogma sections
                if baseName == "dogmaAttributes",
                   var dict = finalData as? [String: Any] {
                    var entries: [Int: [String: Any]] = Dictionary(uniqueKeysWithValues: dict.compactMap({ key, value in
                        guard let intKey = Int(key), let v = value as? [String: Any] else { return nil }
                        return (intKey, v)
                    }))
                    do {
                        if let attrPatches = patches["attributes"] as? [[String: Any]] {
                            try applyDogmaAttributePatches(to: &entries, using: attrPatches)
                            print("✅ Successfully applied attribute patches for \(baseName)")
                        }
                        finalData = Dictionary(uniqueKeysWithValues: entries.map { (k, v) in ("\(k)", v) })
                    } catch {
                        print("⚠️ Error applying attribute patches: \(error)")
                    }
                } else if baseName == "dogmaEffects",
                          var dict = finalData as? [String: Any] {
                    var entries: [Int: [String: Any]] = Dictionary(uniqueKeysWithValues: dict.compactMap({ key, value in
                        guard let intKey = Int(key), let v = value as? [String: Any] else { return nil }
                        return (intKey, v)
                    }))
                    do {
                        if let effPatches = patches["effects"] as? [[String: Any]] {
                            // Pass complete YAML data context for cross-references
                            try applyDogmaEffectPatches(to: &entries, using: effPatches, data: allYamlData)
                            print("✅ Successfully applied effect patches for \(baseName)")
                        }
                        finalData = Dictionary(uniqueKeysWithValues: entries.map { (k, v) in ("\(k)", v) })
                    } catch {
                        print("⚠️ Error applying effect patches: \(error)")
                    }
                } else if baseName == "typeDogma",
                          var dict = finalData as? [String: Any] {
                    var entries: [Int: [String: Any]] = Dictionary(uniqueKeysWithValues: dict.compactMap({ key, value in
                        guard let intKey = Int(key), let v = value as? [String: Any] else { return nil }
                        return (intKey, v)
                    }))
                    do {
                        if let tdPatches = patches["typeDogma"] as? [[String: Any]] {
                            // Pass complete YAML data context for cross-references
                            try applyTypeDogmaPatches(to: &entries, using: tdPatches, data: allYamlData)
                            print("✅ Successfully applied typeDogma patches for \(baseName)")
                        }
                        finalData = Dictionary(uniqueKeysWithValues: entries.map { (k, v) in ("\(k)", v) })
                    } catch {
                        print("⚠️ Error applying typeDogma patches: \(error)")
                    }
                }

                if let dict = allYamlData[baseName] as? [String: Any],
                   dict.keys.allSatisfy({ Int($0) != nil }) {
                    let sortedDict = dict
                        .compactMap { (key, value) -> (Int, Any)? in
                            guard let intKey = Int(key) else { return nil }
                            return (intKey, value)
                        }
                        .sorted(by: { $0.0 < $1.0 })

                    finalData = Dictionary(uniqueKeysWithValues: sortedDict.map { (key, value) in ("\(key)", value) })
                }

                let relativePath = fileURL.path.replacingOccurrences(of: resourcesRoot.path, with: "")
                let jsonDestinationRoot = resourcesRoot.appendingPathComponent("sde-json")
                let jsonURL = jsonDestinationRoot.appendingPathComponent(relativePath)
                    .deletingPathExtension()
                    .appendingPathExtension("json")

                try fileManager.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let jsonData = try JSONSerialization.data(withJSONObject: finalData, options: [.prettyPrinted])
                try jsonData.write(to: jsonURL)
                // print("✅ Converted \(fileURL.lastPathComponent) → \(jsonURL.lastPathComponent)")
            } catch {
                print("❌ Error processing \(fileURL.path): \(error)")
            }
        }
    }

    group.wait()
    let elapsedTime = Date().timeIntervalSince(startTime)
    print(String(format: "⏱ Time elapsed: %.2f seconds", elapsedTime))
}

processYAMLFiles(in: resourcesRoot)
