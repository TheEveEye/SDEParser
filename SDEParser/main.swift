import Darwin
import Foundation

let fileManager = FileManager.default
let projectRoot = URL(fileURLWithPath: #file).deletingLastPathComponent()
let resourcesRoot = projectRoot.appendingPathComponent("Resources")
let sdeSourceRoot = resourcesRoot.appendingPathComponent("sde")
let jsonDestinationRoot = resourcesRoot.appendingPathComponent("sde-json")
let sdeDestinationRoot = jsonDestinationRoot.appendingPathComponent("sde")
let workspaceRoot = projectRoot
    .deletingLastPathComponent() // SDEParser project
    .deletingLastPathComponent() // workspace
let appSDEDestinationRoot = workspaceRoot
    .appendingPathComponent("KiwiFitting")
    .appendingPathComponent("KiwiFitting")
    .appendingPathComponent("Resources")
    .appendingPathComponent("sde")
let latestBuildURL = URL(
    string: "https://developers.eveonline.com/static-data/tranquility/latest.jsonl"
)!

// These are the SDE datasets consumed by KiwiFitting and its dogma engine.
let datasetNames = [
    "categories",
    "dogmaAttributes",
    "dogmaEffects",
    "groups",
    "icons",
    "marketGroups",
    "metaGroups",
    "typeDogma",
    "types",
]

let clearDestinationFirst = true

enum SDEParserError: Error, CustomStringConvertible {
    case invalidBuildMetadata
    case downloadFailed(statusCode: Int)
    case extractionFailed(String)
    case missingDatasets([String])
    case invalidRecord(file: String, line: Int)
    case missingKey(file: String, line: Int)
    case invalidKey(file: String, line: Int)
    case duplicateKey(file: String, key: String)
    case expectedObject(dataset: String, key: String)

    var description: String {
        switch self {
        case .invalidBuildMetadata:
            return "CCP's latest.jsonl response did not contain an SDE build number"
        case .downloadFailed(let statusCode):
            return "SDE download failed with HTTP status \(statusCode)"
        case .extractionFailed(let message):
            return "Could not extract SDE archive: \(message)"
        case .missingDatasets(let names):
            return "Missing JSONL datasets: \(names.joined(separator: ", "))"
        case .invalidRecord(let file, let line):
            return "\(file):\(line) is not a JSON object"
        case .missingKey(let file, let line):
            return "\(file):\(line) has no _key"
        case .invalidKey(let file, let line):
            return "\(file):\(line) has an unsupported _key"
        case .duplicateKey(let file, let key):
            return "\(file) contains duplicate key \(key)"
        case .expectedObject(let dataset, let key):
            return "\(dataset) entry \(key) is not an object"
        }
    }
}

/// JSONSerialization produces heterogeneous value trees that are not declared
/// Sendable. Each tree is built by one task, transferred once, and then only
/// accessed after that task has finished, so this wrapper is safe to transfer.
struct LoadedDataset: @unchecked Sendable {
    let index: Int
    let name: String
    let entries: [String: Any]
}

struct PublishedDataset: Sendable {
    let fileName: String
}

func fetchLatestBuildNumber() async throws -> String {
    let (data, response) = try await URLSession.shared.data(from: latestBuildURL)
    if let response = response as? HTTPURLResponse,
       !(200..<300).contains(response.statusCode) {
        throw SDEParserError.downloadFailed(statusCode: response.statusCode)
    }

    for line in data.split(separator: 0x0A) {
        guard let record = try JSONSerialization.jsonObject(
            with: Foundation.Data(line)
        ) as? [String: Any],
              record["_key"] as? String == "sde" else {
            continue
        }

        let rawBuild = record["_value"] ?? record["buildNumber"] ?? record["build"]
        if let build = rawBuild as? NSNumber {
            return build.stringValue
        }
        if let build = rawBuild as? String, !build.isEmpty {
            return build
        }
    }

    throw SDEParserError.invalidBuildMetadata
}

func localBuildNumber() -> String? {
    let buildURL = sdeSourceRoot.appendingPathComponent("build-number.txt")
    guard let value = try? String(contentsOf: buildURL, encoding: .utf8) else {
        return nil
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func hasAllSourceDatasets() -> Bool {
    datasetNames.allSatisfy { baseName in
        fileManager.fileExists(
            atPath: sdeSourceRoot
                .appendingPathComponent(baseName)
                .appendingPathExtension("jsonl")
                .path
        )
    }
}

func extractArchive(at archiveURL: URL, to destinationURL: URL) throws {
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8)
            ?? "ditto exited with status \(process.terminationStatus)"
        throw SDEParserError.extractionFailed(message)
    }
}

func installDatasets(from extractedRoot: URL, buildNumber: String) throws {
    guard let enumerator = fileManager.enumerator(
        at: extractedRoot,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        throw CocoaError(.fileReadNoSuchFile)
    }

    var extractedFiles: [String: URL] = [:]
    for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        if datasetNames.contains(baseName) {
            extractedFiles[baseName] = fileURL
        }
    }

    let missing = datasetNames.filter { extractedFiles[$0] == nil }
    guard missing.isEmpty else {
        throw SDEParserError.missingDatasets(missing)
    }

    try fileManager.createDirectory(at: sdeSourceRoot, withIntermediateDirectories: true)
    for baseName in datasetNames {
        guard let sourceURL = extractedFiles[baseName] else { continue }
        let destinationURL = sdeSourceRoot
            .appendingPathComponent(baseName)
            .appendingPathExtension("jsonl")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    try (buildNumber + "\n").write(
        to: sdeSourceRoot.appendingPathComponent("build-number.txt"),
        atomically: true,
        encoding: .utf8
    )
}

@MainActor
func updateSourceSDEIfNeeded() async throws {
    let buildNumber = try await fetchLatestBuildNumber()
    if localBuildNumber() == buildNumber, hasAllSourceDatasets() {
        print("✅ SDE build \(buildNumber) is already downloaded")
        return
    }

    print("⬇️ Downloading SDE build \(buildNumber)")
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("KiwiFitting-SDE-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let archiveURL = URL(
        string: "https://developers.eveonline.com/static-data/tranquility/eve-online-static-data-\(buildNumber)-jsonl.zip"
    )!
    let (downloadedURL, response) = try await URLSession.shared.download(from: archiveURL)
    if let response = response as? HTTPURLResponse,
       !(200..<300).contains(response.statusCode) {
        throw SDEParserError.downloadFailed(statusCode: response.statusCode)
    }

    let localArchiveURL = temporaryRoot.appendingPathComponent("sde.zip")
    try fileManager.moveItem(at: downloadedURL, to: localArchiveURL)
    let extractedRoot = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
    try extractArchive(at: localArchiveURL, to: extractedRoot)
    try installDatasets(from: extractedRoot, buildNumber: buildNumber)
    print("✅ Installed SDE build \(buildNumber)")
}

/// Reads a file incrementally so large JSONL datasets do not need a second,
/// whole-file string allocation in addition to the parsed records.
func forEachLine(
    at fileURL: URL,
    _ body: (Foundation.Data, Int) throws -> Void
) throws {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var buffer = Foundation.Data()
    var lineNumber = 0

    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        var lineStart = buffer.startIndex

        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            lineNumber += 1
            try body(Foundation.Data(buffer[lineStart..<newline]), lineNumber)
            lineStart = buffer.index(after: newline)
        }

        if lineStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
    }

    if !buffer.isEmpty {
        lineNumber += 1
        try body(buffer, lineNumber)
    }
}

func stringKey(from value: Any) -> String? {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return nil
}

/// Indexes JSONL records by `_key` while patches are applied. All other SDE
/// field names and values are retained unchanged.
func loadJSONLines(at fileURL: URL) throws -> [String: Any] {
    var entries: [String: Any] = [:]

    try forEachLine(at: fileURL) { line, lineNumber in
        guard !line.allSatisfy({ byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        }) else {
            return
        }

        guard var record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw SDEParserError.invalidRecord(file: fileURL.lastPathComponent, line: lineNumber)
        }
        guard let rawKey = record.removeValue(forKey: "_key") else {
            throw SDEParserError.missingKey(file: fileURL.lastPathComponent, line: lineNumber)
        }
        guard let key = stringKey(from: rawKey) else {
            throw SDEParserError.invalidKey(file: fileURL.lastPathComponent, line: lineNumber)
        }
        guard entries[key] == nil else {
            throw SDEParserError.duplicateKey(file: fileURL.lastPathComponent, key: key)
        }

        if record.count == 1, let value = record["_value"] {
            entries[key] = value
        } else {
            entries[key] = record
        }
    }

    return entries
}

func objectEntries(
    in data: [String: Any],
    named dataset: String
) throws -> [Int: [String: Any]] {
    guard let rawEntries = data[dataset] as? [String: Any] else {
        return [:]
    }

    var entries: [Int: [String: Any]] = [:]
    for (key, value) in rawEntries {
        guard let integerKey = Int(key), let object = value as? [String: Any] else {
            throw SDEParserError.expectedObject(dataset: dataset, key: key)
        }
        entries[integerKey] = object
    }
    return entries
}

func stringKeyed(_ entries: [Int: [String: Any]]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
}

func discoverJSONLinesFiles() throws -> [String: URL] {
    guard let enumerator = fileManager.enumerator(
        at: sdeSourceRoot,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        throw CocoaError(.fileReadNoSuchFile)
    }

    var files: [String: URL] = [:]
    for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        if datasetNames.contains(baseName) {
            files[baseName] = fileURL
        }
    }

    let missing = datasetNames.filter { files[$0] == nil }
    guard missing.isEmpty else {
        throw SDEParserError.missingDatasets(missing)
    }
    return files
}

func maximumConcurrentJobCount(for datasetCount: Int) -> Int {
    let environment = ProcessInfo.processInfo.environment
    if let value = environment["SDE_PARSER_JOBS"],
       let requestedCount = Int(value),
       requestedCount > 0 {
        return min(requestedCount, datasetCount)
    }

    return min(ProcessInfo.processInfo.activeProcessorCount, datasetCount)
}

@MainActor
func loadDatasets(
    named names: [String],
    from files: [String: URL],
    maximumConcurrentJobs: Int
) async throws -> [String: Any] {
    let jobs = names.enumerated().compactMap { index, name -> (Int, String, URL)? in
        guard let fileURL = files[name] else { return nil }
        return (index, name, fileURL)
    }

    return try await withThrowingTaskGroup(of: LoadedDataset.self) { group in
        let initialJobCount = min(maximumConcurrentJobs, jobs.count)
        for job in jobs.prefix(initialJobCount) {
            group.addTask {
                LoadedDataset(
                    index: job.0,
                    name: job.1,
                    entries: try loadJSONLines(at: job.2)
                )
            }
        }

        var nextJobIndex = initialJobCount
        var completedJobCount = 0
        var loadedDatasets: [LoadedDataset?] = Array(repeating: nil, count: jobs.count)

        while let dataset = try await group.next() {
            completedJobCount += 1
            loadedDatasets[dataset.index] = dataset
            print("📥 \(completedJobCount)/\(jobs.count) | Loaded \(dataset.name).jsonl")

            if nextJobIndex < jobs.count {
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    LoadedDataset(
                        index: job.0,
                        name: job.1,
                        entries: try loadJSONLines(at: job.2)
                    )
                }
            }
        }

        var allSDEData: [String: Any] = [:]
        for dataset in loadedDatasets.compactMap({ $0 }) {
            allSDEData[dataset.name] = dataset.entries
        }
        return allSDEData
    }
}

@MainActor
func publishDatasets(
    named names: [String],
    from allSDEData: [String: Any],
    maximumConcurrentJobs: Int
) async throws {
    let jobs = names.enumerated().compactMap { index, name -> LoadedDataset? in
        guard let entries = allSDEData[name] as? [String: Any] else { return nil }
        return LoadedDataset(index: index, name: name, entries: entries)
    }

    try await withThrowingTaskGroup(of: PublishedDataset.self) { group in
        let initialJobCount = min(maximumConcurrentJobs, jobs.count)
        for job in jobs.prefix(initialJobCount) {
            group.addTask {
                let outputURL = sdeDestinationRoot
                    .appendingPathComponent(job.name)
                    .appendingPathExtension("json")
                let appResourceURL = appSDEDestinationRoot
                    .appendingPathComponent(job.name)
                    .appendingPathExtension("json")
                try writeJSON(job.entries, to: outputURL)
                try writeJSON(job.entries, to: appResourceURL)
                return PublishedDataset(fileName: outputURL.lastPathComponent)
            }
        }

        var nextJobIndex = initialJobCount
        var completedJobCount = 0
        while let dataset = try await group.next() {
            completedJobCount += 1
            print("📦 \(completedJobCount)/\(jobs.count) | Published \(dataset.fileName)")

            if nextJobIndex < jobs.count {
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    let outputURL = sdeDestinationRoot
                        .appendingPathComponent(job.name)
                        .appendingPathExtension("json")
                    let appResourceURL = appSDEDestinationRoot
                        .appendingPathComponent(job.name)
                        .appendingPathExtension("json")
                    try writeJSON(job.entries, to: outputURL)
                    try writeJSON(job.entries, to: appResourceURL)
                    return PublishedDataset(fileName: outputURL.lastPathComponent)
                }
            }
        }
    }
}

func applyPatches(to allSDEData: inout [String: Any], patches: [String: Any]) throws {
    var attributes = try objectEntries(in: allSDEData, named: "dogmaAttributes")
    if let attributePatches = patches["attributes"] as? [[String: Any]] {
        try applyDogmaAttributePatches(to: &attributes, using: attributePatches)
    }
    allSDEData["dogmaAttributes"] = stringKeyed(attributes)

    var effects = try objectEntries(in: allSDEData, named: "dogmaEffects")
    if let effectPatches = patches["effects"] as? [[String: Any]] {
        try applyDogmaEffectPatches(to: &effects, using: effectPatches, data: allSDEData)
    }
    allSDEData["dogmaEffects"] = stringKeyed(effects)

    var typeDogma = try objectEntries(in: allSDEData, named: "typeDogma")
    if let typeDogmaPatches = patches["typeDogma"] as? [[String: Any]] {
        try applyTypeDogmaPatches(to: &typeDogma, using: typeDogmaPatches, data: allSDEData)
    }
    allSDEData["typeDogma"] = stringKeyed(typeDogma)
}

func writeJSON(_ object: Any, to url: URL) throws {
    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
}

func writeTypeIndex(from allSDEData: [String: Any]) throws {
    guard let types = allSDEData["types"] as? [String: Any] else {
        throw SDEParserError.expectedObject(dataset: "types", key: "<root>")
    }

    var byID: [String: String] = [:]
    var byName: [String: [Int]] = [:]

    for (typeID, value) in types {
        guard let integerID = Int(typeID), let type = value as? [String: Any] else {
            continue
        }
        let localizedName = type["name"] as? [String: Any]
        let name = localizedName?["en"] as? String ?? type["name"] as? String
        guard let name, !name.isEmpty else { continue }

        byID[typeID] = name
        byName[name, default: []].append(integerID)
    }

    for name in byName.keys {
        byName[name]?.sort()
    }

    let index: [String: Any] = ["byID": byID, "byName": byName]
    try writeJSON(
        index,
        to: jsonDestinationRoot.appendingPathComponent("typesIndex.json")
    )
    try writeJSON(
        index,
        to: appSDEDestinationRoot.appendingPathComponent("typesIndex.json")
    )
}

func writeShipTypes(from allSDEData: [String: Any]) throws {
    let types = try objectEntries(in: allSDEData, named: "types")
    let groups = try objectEntries(in: allSDEData, named: "groups")

    let shipTypes = types.compactMap { typeID, type -> [String: Any]? in
        guard type["published"] as? Bool == true,
              let groupID = type["groupID"] as? Int,
              let group = groups[groupID],
              group["categoryID"] as? Int == 6,
              let localizedName = type["name"] as? [String: Any],
              let name = localizedName["en"] as? String else {
            return nil
        }

        var shipType: [String: Any] = [
            "typeID": typeID,
            "name": name,
            "groupID": groupID,
        ]
        if let marketGroupID = type["marketGroupID"] as? Int {
            shipType["marketGroupID"] = marketGroupID
        }
        if let factionID = type["factionID"] as? Int {
            shipType["factionID"] = factionID
        }
        return shipType
    }
    .sorted {
        ($0["typeID"] as? Int ?? 0) < ($1["typeID"] as? Int ?? 0)
    }

    try writeJSON(
        shipTypes,
        to: jsonDestinationRoot.appendingPathComponent("shipTypes.json")
    )
    try writeJSON(
        shipTypes,
        to: appSDEDestinationRoot.appendingPathComponent("shipTypes.json")
    )
}

func writeModuleTypes(from allSDEData: [String: Any]) throws {
    let types = try objectEntries(in: allSDEData, named: "types")
    let marketGroups = try objectEntries(in: allSDEData, named: "marketGroups")
    let typeDogma = try objectEntries(in: allSDEData, named: "typeDogma")
    let moduleMarketRootIDs: Set<Int> = [9, 955]

    func descendsFromModuleMarketRoot(_ marketGroupID: Int) -> Bool {
        var currentID = marketGroupID
        var visited = Set<Int>()

        while visited.insert(currentID).inserted {
            guard !moduleMarketRootIDs.contains(currentID) else { return true }
            guard let parentID = marketGroups[currentID]?["parentGroupID"] as? Int else {
                return false
            }
            currentID = parentID
        }

        return false
    }

    func fittingSlot(for typeID: Int) -> String? {
        guard let effects = typeDogma[typeID]?["dogmaEffects"] as? [[String: Any]] else {
            return nil
        }
        let effectIDs = Set(effects.compactMap { $0["effectID"] as? Int })

        if effectIDs.contains(12) { return "high" }
        if effectIDs.contains(13) { return "medium" }
        if effectIDs.contains(11) { return "low" }
        if effectIDs.contains(2_663) { return "rig" }
        if effectIDs.contains(3_772) { return "subsystem" }
        return nil
    }

    let moduleTypes = types.compactMap { typeID, type -> [String: Any]? in
        guard type["published"] as? Bool == true,
              let marketGroupID = type["marketGroupID"] as? Int,
              descendsFromModuleMarketRoot(marketGroupID),
              let slot = fittingSlot(for: typeID),
              let localizedName = type["name"] as? [String: Any],
              let name = localizedName["en"] as? String else {
            return nil
        }

        return [
            "typeID": typeID,
            "name": name,
            "marketGroupID": marketGroupID,
            "slot": slot,
        ]
    }
    .sorted {
        ($0["typeID"] as? Int ?? 0) < ($1["typeID"] as? Int ?? 0)
    }

    try writeJSON(
        moduleTypes,
        to: jsonDestinationRoot.appendingPathComponent("moduleTypes.json")
    )
    try writeJSON(
        moduleTypes,
        to: appSDEDestinationRoot.appendingPathComponent("moduleTypes.json")
    )
}

@MainActor
func processSDE() async throws {
    let startTime = Date()
    try await updateSourceSDEIfNeeded()
    let files = try discoverJSONLinesFiles()

    if clearDestinationFirst, fileManager.fileExists(atPath: jsonDestinationRoot.path) {
        try fileManager.removeItem(at: jsonDestinationRoot)
    }
    try fileManager.createDirectory(at: sdeDestinationRoot, withIntermediateDirectories: true)

    let maximumConcurrentJobs = maximumConcurrentJobCount(for: datasetNames.count)
    print("⚙️ Using up to \(maximumConcurrentJobs) concurrent dataset jobs")

    var allSDEData = try await loadDatasets(
        named: datasetNames,
        from: files,
        maximumConcurrentJobs: maximumConcurrentJobs
    )

    let patches = try loadPatches(at: resourcesRoot.appendingPathComponent("patches"))
    try applyPatches(to: &allSDEData, patches: patches)

    try await publishDatasets(
        named: datasetNames,
        from: allSDEData,
        maximumConcurrentJobs: maximumConcurrentJobs
    )

    try writeTypeIndex(from: allSDEData)
    print("🧭 Generated typesIndex.json")
    try writeShipTypes(from: allSDEData)
    print("🚀 Generated shipTypes.json")
    try writeModuleTypes(from: allSDEData)
    print("🧩 Generated moduleTypes.json")
    print(String(format: "🏁 Completed in %.2f seconds", Date().timeIntervalSince(startTime)))
}

do {
    try await processSDE()
} catch {
    fputs("❌ SDE parsing failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
