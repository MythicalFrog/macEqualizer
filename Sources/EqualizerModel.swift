import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation

enum AudioChannel: String, CaseIterable, Identifiable {
    case left = "Left"
    case right = "Right"

    var id: String { rawValue }
}

enum FilterShape: String, CaseIterable, Identifiable, Codable {
    case peak = "Peak"
    case lowShelf = "Low Shelf"
    case highShelf = "High Shelf"

    var id: String { rawValue }
}

enum RoutePreset: String, CaseIterable, Identifiable {
    case reference = "Reference"
    case game = "Game Imaging"
    case voice = "Voice Cleanup"
    case cinema = "Cinema"

    var id: String { rawValue }
}

enum ConditionTrigger: String, CaseIterable, Identifiable {
    case outputDevice = "Output Device"
    case applicationLaunch = "Application Launch"

    var id: String { rawValue }
}

enum AnalyzerMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case live = "Live"

    var id: String { rawValue }
}

struct ParametricBand: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var frequency: Double
    var gain: Double
    var q: Double
    var shape: FilterShape
    var isEnabled: Bool
    var isDynamic: Bool
    var threshold: Double
    var ratio: Double

    var displayFrequency: String {
        if frequency >= 1000 {
            return String(format: "%.1f kHz", frequency / 1000)
        }
        return String(format: "%.0f Hz", frequency)
    }
}

struct AppRoute: Identifiable, Equatable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String?
    var pid: Int
    var volume: Double
    var preset: RoutePreset
    var effectsEnabled = true
    var pluginsEnabled = false
}

struct DiscoveredPlugin: Identifiable {
    var id = UUID()
    var name: String
    var type: OSType
    var subtype: OSType
    var manufacturer: OSType
}

struct PluginSlot: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var format: String
    var isEnabled: Bool
    var wetMix: Double
    var latencyMS: Double
    var serializedState: String
    var componentType: OSType = 0
    var componentSubtype: OSType = 0
    var componentManufacturer: OSType = 0
}

struct SpectrumBin: Equatable {
    var frequency: Double
    var magnitude: Double
}

struct CurvePoint: Equatable {
    var frequency: Double
    var gain: Double
}

struct AutoEQProfile: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let target: String
    let path: String
}

struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static let bypass = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

struct ConditionRule: Identifiable, Equatable {
    var id = UUID()
    var trigger: ConditionTrigger
    var matchValue: String
    var preset: RoutePreset
    var isEnabled: Bool
}

final class EqualizerModel: ObservableObject {

    @Published var selectedChannel: AudioChannel = .left
    @Published var linkChannels = false
    @Published var analyzerEnabled = true
    @Published var analyzerMode: AnalyzerMode = .live
    @Published var activeOutputDevice = "Headphones"
    @Published var lastLaunchedApp = "Safari"
    @Published var activePreset: RoutePreset = .reference

    @Published var leftBands: [ParametricBand] = []
    @Published var rightBands: [ParametricBand] = []

    @Published var routes: [AppRoute] = []

    @Published var pluginChain: [PluginSlot] = []
    @Published var pluginCatalog: [DiscoveredPlugin] = []

    @Published var conditionRules: [ConditionRule] = [
        ConditionRule(trigger: .outputDevice, matchValue: "Built-in Speakers", preset: .cinema, isEnabled: true),
        ConditionRule(trigger: .outputDevice, matchValue: "Headphones", preset: .reference, isEnabled: true),
        ConditionRule(trigger: .applicationLaunch, matchValue: "Discord", preset: .voice, isEnabled: true),
        ConditionRule(trigger: .applicationLaunch, matchValue: "Game", preset: .game, isEnabled: true)
    ]

    @Published var currentOutputDeviceName = ""
    private var lastOutputDevice = ""

    @Published var isAutoEQEnabled = false
    @Published var autoEQStatus = "idle"
    @Published var autoEQStatusMessage = ""
    @Published var autoEQAppliedCSV = ""

    @Published var selectedAutoEQProfileID: UUID?
    @Published var autoEQProfiles: [AutoEQProfile] = [
        AutoEQProfile(title: "HD 600", target: "Neutral", path: "results/Headphones/Sennheiser/Sennheiser HD 600"),
        AutoEQProfile(title: "DT 990 Pro", target: "Neutral", path: "results/Headphones/Beyerdynamic/Beyerdynamic DT 990 Pro"),
        AutoEQProfile(title: "AirPods Pro", target: "Neutral", path: "results/in-ear/Apple/AirPods Pro"),
    ]

    @Published var eqTransitionEnabled = true
    @Published var eqTransitionDuration: Double = 3.0
    @Published var isTransitioning = false

    var isAutoEQApplying = false

    private var autoEQCaches: [String: String] = [:]
    private let autoEQCachesKey = "AutoEQTrackCache"
    private var transitionFromBands: [ParametricBand] = []
    private var transitionToBands: [ParametricBand] = []
    private var transitionStartTime: CFAbsoluteTime = 0
    private var transitionTimer: Timer?

    init() {
        loadAutoEQCaches()
    }

    var activeBands: [ParametricBand] {
        selectedChannel == .left ? leftBands : rightBands
    }

    var activeRouteCount: Int {
        routes.count
    }

    var enabledPluginCount: Int {
        pluginChain.filter(\.isEnabled).count
    }

    func addBand() {
        let band = ParametricBand(
            name: "Node \(activeBands.count + 1)",
            frequency: 1000,
            gain: 0,
            q: 1,
            shape: .peak,
            isEnabled: true,
            isDynamic: false,
            threshold: -18,
            ratio: 2
        )

        mutateBands(for: selectedChannel) { bands in
            bands.append(band)
        }
    }

    func deleteBand(_ band: ParametricBand) {
        mutateBands(for: selectedChannel) { bands in
            bands.removeAll { $0.id == band.id }
        }
    }

    func bindChannelsFromLeftIfNeeded() {
        guard linkChannels else { return }
        rightBands = leftBands.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
    }

    func copyLeftToRight() {
        rightBands = leftBands.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
    }

    func copyRightToLeft() {
        leftBands = rightBands.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
    }

    func parseAutoEQCSVToBands(_ csv: String) -> [ParametricBand] {
        csv
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ParametricBand? in
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 3,
                      let frequency = Double(parts[0]),
                      let gain = Double(parts[1]),
                      let q = Double(parts[2]) else { return nil }

                let isDynamic: Bool
                let threshold: Double
                let ratio: Double
                if parts.count >= 6 {
                    isDynamic = parts[3].lowercased() == "1" || parts[3].lowercased() == "true"
                    threshold = Double(parts[4]) ?? -18
                    ratio = Double(parts[5]) ?? 3
                } else if parts.count >= 4 {
                    isDynamic = parts[3].lowercased() == "1" || parts[3].lowercased() == "true"
                    threshold = -18
                    ratio = 3
                } else {
                    isDynamic = false
                    threshold = -18
                    ratio = 3
                }

                return ParametricBand(
                    name: "\(Int(frequency)) Hz",
                    frequency: frequency,
                    gain: gain,
                    q: q,
                    shape: .peak,
                    isEnabled: true,
                    isDynamic: isDynamic,
                    threshold: threshold,
                    ratio: ratio
                )
            }
    }

    func parseAutoEQCSV(_ csv: String) {
        let parsedBands = parseAutoEQCSVToBands(csv)
        guard !parsedBands.isEmpty else { return }
        leftBands = parsedBands
        rightBands = parsedBands.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
    }

    func startEQTransition(to targetBands: [ParametricBand]) {
        guard !targetBands.isEmpty else { return }

        if eqTransitionEnabled && eqTransitionDuration > 0 && isTransitioning {
            transitionFromBands = currentInterpolatedBands()
        } else if eqTransitionEnabled && eqTransitionDuration > 0 {
            transitionFromBands = leftBands
        } else {
            isAutoEQApplying = true
            leftBands = targetBands
            rightBands = targetBands.map { band in
                var copy = band
                copy.id = UUID()
                return copy
            }
            DispatchQueue.main.async { [weak self] in self?.isAutoEQApplying = false }
            return
        }

        transitionToBands = targetBands
        transitionStartTime = CFAbsoluteTimeGetCurrent()
        isTransitioning = true

        transitionTimer?.invalidate()
        transitionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickTransition()
            }
        }
    }

    private func tickTransition() {
        let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
        let duration = max(eqTransitionDuration, 0.01)
        let rawProgress = min(elapsed / duration, 1.0)
        let t = rawProgress < 0.5 ? 2 * rawProgress * rawProgress : 1 - pow(-2 * rawProgress + 2, 2) / 2

        let from = transitionFromBands
        let to = transitionToBands
        let count = max(from.count, to.count)

        var interpolated: [ParametricBand] = []
        for i in 0..<count {
            let a = i < from.count ? from[i] : ParametricBand(
                name: "Flat \(i)", frequency: to[i].frequency, gain: 0, q: 1,
                shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 3
            )
            let b = i < to.count ? to[i] : ParametricBand(
                name: "Flat \(i)", frequency: a.frequency, gain: 0, q: 1,
                shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 3
            )

            interpolated.append(ParametricBand(
                name: b.name,
                frequency: a.frequency + (b.frequency - a.frequency) * t,
                gain: a.gain + (b.gain - a.gain) * t,
                q: a.q + (b.q - a.q) * t,
                shape: b.shape,
                isEnabled: b.isEnabled,
                isDynamic: b.isDynamic,
                threshold: b.threshold,
                ratio: b.ratio
            ))
        }

        isAutoEQApplying = true
        leftBands = interpolated
        rightBands = interpolated.map { band in
            var copy = band
            copy.id = UUID()
            return copy
        }
        DispatchQueue.main.async { [weak self] in self?.isAutoEQApplying = false }

        if rawProgress >= 1.0 {
            isTransitioning = false
            transitionTimer?.invalidate()
            transitionTimer = nil
        }
    }

    private func currentInterpolatedBands() -> [ParametricBand] {
        guard isTransitioning else { return leftBands }

        let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
        let duration = max(eqTransitionDuration, 0.01)
        let rawProgress = min(elapsed / duration, 1.0)
        let t = rawProgress < 0.5 ? 2 * rawProgress * rawProgress : 1 - pow(-2 * rawProgress + 2, 2) / 2

        let from = transitionFromBands
        let to = transitionToBands
        let count = max(from.count, to.count)

        var bands: [ParametricBand] = []
        for i in 0..<count {
            let a = i < from.count ? from[i] : ParametricBand(
                name: "Flat \(i)", frequency: to[i].frequency, gain: 0, q: 1,
                shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 3
            )
            let b = i < to.count ? to[i] : ParametricBand(
                name: "Flat \(i)", frequency: a.frequency, gain: 0, q: 1,
                shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 3
            )

            bands.append(ParametricBand(
                name: b.name,
                frequency: a.frequency + (b.frequency - a.frequency) * t,
                gain: a.gain + (b.gain - a.gain) * t,
                q: a.q + (b.q - a.q) * t,
                shape: b.shape,
                isEnabled: b.isEnabled,
                isDynamic: b.isDynamic,
                threshold: b.threshold,
                ratio: b.ratio
            ))
        }
        return bands
    }

    @Published var autoEqSearchQuery = ""
    @Published var autoEqSearchResults: [AutoEqSearchResult] = []
    @Published var autoEqSearchStatus = ""
    @Published var autoEqIndexLoaded = false

    private var autoEqIndexLines: [String] = []
    private let autoEqIndexCacheKey = "AutoEqIndexCacheV2"

    struct AutoEqSearchResult: Identifiable, Equatable {
        let id = UUID()
        let displayName: String
        let path: String
        let source: String
    }

    private func loadAutoEqIndex() {
        guard !autoEqIndexLoaded else { return }
        if let cached = UserDefaults.standard.string(forKey: autoEqIndexCacheKey), !cached.isEmpty {
            autoEqIndexLines = cached.components(separatedBy: .newlines).filter { $0.hasPrefix("- [") }
            autoEqIndexLoaded = true
            return
        }
        autoEqIndexLines = []
        autoEqIndexLoaded = false
    }

    func downloadAutoEqIndex() {
        autoEqSearchStatus = "Downloading index..."
        let urlString = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md"
        guard let url = URL(string: urlString) else { return }

        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    autoEqSearchStatus = "Failed to decode index"
                    return
                }
                UserDefaults.standard.set(text, forKey: autoEqIndexCacheKey)
                autoEqIndexLines = text.components(separatedBy: .newlines).filter { $0.hasPrefix("- [") }
                autoEqIndexLoaded = true
                autoEqSearchStatus = "Index ready (\(autoEqIndexLines.count) profiles)"
            } catch {
                autoEqSearchStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func searchAutoEq() {
        let query = autoEqSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        loadAutoEqIndex()

        guard autoEqIndexLoaded else {
            downloadAutoEqIndex()
            return
        }

        autoEqSearchStatus = "Searching..."
        autoEqSearchResults = []

        let lowerQuery = query.lowercased()
        var results: [AutoEqSearchResult] = []

        for line in autoEqIndexLines {
            guard results.count < 10 else { break }
            guard let nameRange = line.range(of: "["),
                  let nameEndRange = line.range(of: "]", range: nameRange.upperBound..<line.endIndex) else { continue }

            let displayName = String(line[nameRange.upperBound..<nameEndRange.lowerBound])
            guard displayName.lowercased().contains(lowerQuery) else { continue }

            guard let parenStart = line.range(of: "(", range: nameEndRange.upperBound..<line.endIndex),
                  let parenEnd = line.range(of: ")", range: parenStart.upperBound..<line.endIndex) else { continue }

            let relPath = String(line[parenStart.upperBound..<parenEnd.lowerBound])
            let path = relPath.hasPrefix("./") ? String(relPath.dropFirst(2)) : relPath

            let source: String
            if let byRange = line.range(of: " by ", range: parenEnd.upperBound..<line.endIndex) {
                source = String(line[byRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                source = ""
            }

            results.append(AutoEqSearchResult(displayName: displayName, path: path, source: source))
        }

        autoEqSearchResults = results
        autoEqSearchStatus = results.isEmpty ? "No results for \"\(query)\"" : "Found \(results.count) result(s)"
    }

    func applyAutoEqProfile(at path: String) {
        let url = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/\(path)")!
        autoEqSearchStatus = "Downloading..."
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    autoEqSearchStatus = "Failed to decode profile"
                    return
                }
                parseAutoEqParametricEQ(text)
                autoEqSearchStatus = "Applied profile"
            } catch {
                autoEqSearchStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func parseAutoEqParametricEQ(_ text: String) {
        var bands: [ParametricBand] = []
        var preampGain: Double = 0

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Preamp:"),
               let gain = Double(trimmed.replacingOccurrences(of: "Preamp:", with: "").replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)) {
                preampGain = gain
                continue
            }
            guard trimmed.hasPrefix("Filter") && trimmed.contains("ON") else { continue }
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 8 else { continue }
            let typeStr = parts[2]
            let freqStr = parts[4].replacingOccurrences(of: "Hz", with: "")
            let gainStr = parts[6].replacingOccurrences(of: "dB", with: "")
            let qStr = parts[8]
            guard let frequency = Double(freqStr),
                  let gain = Double(gainStr),
                  let q = Double(qStr) else { continue }
            let shape: FilterShape
            switch typeStr {
            case "PK": shape = .peak
            case "LS": shape = .lowShelf
            case "HS": shape = .highShelf
            default: shape = .peak
            }
            bands.append(ParametricBand(
                name: "\(Int(frequency)) Hz",
                frequency: frequency,
                gain: gain + preampGain,
                q: q,
                shape: shape,
                isEnabled: true,
                isDynamic: false,
                threshold: -18,
                ratio: 3
            ))
        }

        guard !bands.isEmpty else {
            autoEqSearchStatus = "No parametric EQ filters found"
            return
        }
        leftBands = bands
        rightBands = bands.map { var c = $0; c.id = UUID(); return c }
    }

    func scanForAudioUnits() {
        var component: AudioComponent?
        var results: [DiscoveredPlugin] = []
        while true {
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            component = AudioComponentFindNext(component, &desc)
            guard let comp = component else { break }
            var unmanagedName: Unmanaged<CFString>?
            AudioComponentCopyName(comp, &unmanagedName)
            let name = unmanagedName?.takeRetainedValue() as String? ?? "Unknown"
            var compDesc = AudioComponentDescription()
            AudioComponentGetDescription(comp, &compDesc)
            results.append(DiscoveredPlugin(
                name: name as String? ?? "Unknown",
                type: compDesc.componentType,
                subtype: compDesc.componentSubType,
                manufacturer: compDesc.componentManufacturer
            ))
        }
        pluginCatalog = results.sorted { $0.name < $1.name }
    }

    func addPlugin(_ discovered: DiscoveredPlugin) {
        pluginChain.append(PluginSlot(
            name: discovered.name,
            format: "AU",
            isEnabled: true,
            wetMix: 1.0,
            latencyMS: 0,
            serializedState: "",
            componentType: discovered.type,
            componentSubtype: discovered.subtype,
            componentManufacturer: discovered.manufacturer
        ))
    }

    func removePlugin(at index: Int) {
        pluginChain.remove(at: index)
    }

    func addPluginSlot() {
        pluginChain.append(
            PluginSlot(
                name: "External AU Slot",
                format: "AU",
                isEnabled: true,
                wetMix: 0.5,
                latencyMS: 2.4,
                serializedState: "external-au:empty"
            )
        )
    }

    func movePlugin(from source: IndexSet, to destination: Int) {
        let movingIndexes = source.sorted()
        let movingSlots = movingIndexes.map { pluginChain[$0] }
        for index in movingIndexes.sorted(by: >) {
            pluginChain.remove(at: index)
        }

        let removedBeforeDestination = movingIndexes.filter { $0 < destination }.count
        let insertionIndex = max(0, min(pluginChain.count, destination - removedBeforeDestination))
        pluginChain.insert(contentsOf: movingSlots, at: insertionIndex)
    }

    func simulateOutputDevice(_ device: String) {
        activeOutputDevice = device
        runConditionAutomation(trigger: .outputDevice, value: device)
    }

    func simulateAppLaunch(_ appName: String) {
        lastLaunchedApp = appName
        runConditionAutomation(trigger: .applicationLaunch, value: appName)
    }

    func scanRunningApplications() {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil && Self.isLikelyAudioApp($0) }
            .map { app in
                AppRoute(
                    appName: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    pid: Int(app.processIdentifier),
                    volume: 0.8,
                    preset: .reference
                )
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

        let bundleFallbacks = ["com.apple.Safari", "com.apple.Music", "com.spotify.client", "com.hnc.Discord"]
        var extraApps = [AppRoute]()
        for bundleIdentifier in bundleFallbacks {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
               !runningApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                extraApps.append(
                    AppRoute(
                        appName: app.localizedName ?? bundleIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        pid: Int(app.processIdentifier),
                        volume: 0.8,
                        preset: .reference
                    )
                )
            }
        }

        let apps = (runningApps + extraApps).sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

        let existingRoutes = Dictionary(uniqueKeysWithValues: routes.map { (Self.routeKey(for: $0), $0) })

        routes = apps.enumerated().map { index, app in
            let key = Self.routeKey(for: app)
            if var existing = existingRoutes[key] {
                existing.appName = app.appName
                existing.bundleIdentifier = app.bundleIdentifier
                existing.pid = app.pid
                return existing
            }

            var newRoute = app
            newRoute.preset = RoutePreset.allCases[index % RoutePreset.allCases.count]
            return newRoute
        }

        syncAllRouteVolumes()
    }

    func syncAllRouteVolumes() {
        for route in routes {
            syncAppVolume(for: route.id)
        }
    }

    func syncAppVolume(for routeID: AppRoute.ID) {
        guard let route = routes.first(where: { $0.id == routeID }) else { return }
        setSystemOutputVolume(Float(route.volume))
    }

    private func setSystemOutputVolume(_ volume: Float) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID > 0 else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = volume
        let volSize = UInt32(MemoryLayout<Float>.size)
        AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, volSize, &vol)
    }

    func checkCurrentOutputDevice() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID > 0 else { return }

        var namePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameDataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &namePropertyAddress, 0, nil, &nameDataSize, &name) == noErr,
              let retained = name,
              let deviceName = retained.takeRetainedValue() as String? else { return }

        currentOutputDeviceName = deviceName
        if deviceName != lastOutputDevice {
            lastOutputDevice = deviceName
            runConditionAutomation(trigger: .outputDevice, value: deviceName)
        }
    }

    func autoEQTrack(_ track: TrackInfo, assistant: EQAssistantService) {
        let key = track.cacheKey

        if let cachedCSV = autoEQCaches[key] {
            let bands = parseAutoEQCSVToBands(cachedCSV)
            autoEQAppliedCSV = cachedCSV
            autoEQStatus = "applied"
            autoEQStatusMessage = "Cached: \(track.title)"
            startEQTransition(to: bands)
            return
        }

        autoEQStatus = "querying"
        autoEQStatusMessage = "Querying Gemini for \"\(track.title)\"..."

        Task { @MainActor in
            guard let csv = await assistant.fetchEQCSV(for: track) else {
                autoEQStatus = "error"
                autoEQStatusMessage = "Gemini query failed for \"\(track.title)\""
                return
            }
            autoEQCaches[key] = csv
            saveAutoEQCaches()
            autoEQAppliedCSV = csv
            let bands = parseAutoEQCSVToBands(csv)
            autoEQStatus = "applied"
            autoEQStatusMessage = "EQ applied for \"\(track.title)\""
            startEQTransition(to: bands)
        }
    }

    private func loadAutoEQCaches() {
        guard let data = UserDefaults.standard.data(forKey: autoEQCachesKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        autoEQCaches = dict
    }

    private func saveAutoEQCaches() {
        guard let data = try? JSONEncoder().encode(autoEQCaches) else { return }
        UserDefaults.standard.set(data, forKey: autoEQCachesKey)
    }

    func applyPreset(_ preset: RoutePreset) {
        activePreset = preset
        switch preset {
        case .reference:
            leftBands = [
                ParametricBand(name: "Sub Trim", frequency: 64, gain: -1.8, q: 0.9, shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2),
                ParametricBand(name: "Presence", frequency: 1800, gain: 1.2, q: 1.0, shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2),
                ParametricBand(name: "Air Shelf", frequency: 10_000, gain: 1.4, q: 0.7, shape: .highShelf, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2)
            ]
        case .game:
            leftBands = [
                ParametricBand(name: "Footstep Focus", frequency: 2800, gain: 3.5, q: 1.6, shape: .peak, isEnabled: true, isDynamic: true, threshold: -20, ratio: 2.8),
                ParametricBand(name: "Rumble Control", frequency: 95, gain: -2.8, q: 1.2, shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2),
                ParametricBand(name: "Spatial Air", frequency: 7200, gain: 2.1, q: 0.9, shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2)
            ]
        case .voice:
            leftBands = [
                ParametricBand(name: "Low Cut", frequency: 120, gain: -4.0, q: 0.8, shape: .lowShelf, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2),
                ParametricBand(name: "Intelligibility", frequency: 2400, gain: 3.0, q: 1.3, shape: .peak, isEnabled: true, isDynamic: true, threshold: -22, ratio: 3.2),
                ParametricBand(name: "Sibilance Guard", frequency: 6200, gain: -2.2, q: 2.4, shape: .peak, isEnabled: true, isDynamic: true, threshold: -19, ratio: 4)
            ]
        case .cinema:
            leftBands = [
                ParametricBand(name: "Warmth", frequency: 180, gain: 1.8, q: 0.9, shape: .peak, isEnabled: true, isDynamic: false, threshold: -18, ratio: 2),
                ParametricBand(name: "Dialog Lift", frequency: 1600, gain: 2.4, q: 1.0, shape: .peak, isEnabled: true, isDynamic: true, threshold: -21, ratio: 2.5),
                ParametricBand(name: "Peak Tamer", frequency: 4400, gain: -1.5, q: 1.5, shape: .peak, isEnabled: true, isDynamic: true, threshold: -16, ratio: 3)
            ]
        }

        rightBands = leftBands.map { band in
            var copy = band
            copy.id = UUID()
            copy.name = "\(band.name) R"
            copy.frequency *= 1.015
            return copy
        }
    }

    func mutateBands(for channel: AudioChannel, _ update: (inout [ParametricBand]) -> Void) {
        switch channel {
        case .left:
            update(&leftBands)
            if linkChannels {
                rightBands = leftBands.map { band in
                    var copy = band
                    copy.id = UUID()
                    return copy
                }
            }
        case .right:
            update(&rightBands)
        }
    }

    func runConditionAutomation(trigger: ConditionTrigger, value: String) {
        guard let rule = conditionRules.first(where: {
            $0.isEnabled && $0.trigger == trigger && $0.matchValue.caseInsensitiveCompare(value) == .orderedSame
        }) else { return }

        applyPreset(rule.preset)
    }

    private static func routeKey(for route: AppRoute) -> String {
        routeKey(appName: route.appName, bundleIdentifier: route.bundleIdentifier, pid: route.pid)
    }

    private static func routeKey(appName: String, bundleIdentifier: String?, pid: Int) -> String {
        if let bundleIdentifier {
            return bundleIdentifier.lowercased()
        }
        return "\(appName.lowercased())-\(pid)"
    }

    private static let nonAudioAppNames: Set<String> = [
        "Finder", "System Settings", "System Preferences", "Activity Monitor", "Terminal", "iTerm2",
        "Xcode", "Cursor", "Visual Studio Code", "Notes", "Reminders", "Calendar", "Mail", "Preview",
        "TextEdit", "Calculator", "Dictionary", "Font Book", "Keychain Access", "Console", "Automator",
        "Script Editor", "Photos", "Image Capture", "Screenshot", "Stickies", "Archive Utility",
        "Disk Utility", "Migration Assistant", "Bluetooth File Exchange", "ColorSync Utility",
        "Digital Color Meter", "Grapher", "Audio MIDI Setup", "VoiceOver Utility", "Accessibility Inspector"
    ]

    private static let nonAudioBundleIDPrefixes: [String] = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.ActivityMonitor",
        "com.apple.console",
        "com.apple.archiveutility",
        "com.apple.keychainaccess",
        "com.apple.calculator",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.iCal",
        "com.apple.mail",
        "com.apple.Preview",
        "com.apple.TextEdit",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.apple.Automator",
        "com.apple.ScriptEditor2",
        "com.apple.grapher",
        "com.apple.Dictionary",
        "com.apple.FontBook",
        "com.apple.imagecapture",
        "com.apple.PhotoBooth",
        "com.apple.helpviewer",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.dock"
    ]

    private static let nonAudioBundleIDFragments: [String] = [
        "cursor",
        "vscode",
        "visual-studio-code",
        "sublimetext",
        "jetbrains",
        "docker",
        "github.desktop",
        "figma",
        "sketch",
        "linear",
        "notion",
        "obsidian",
        "1password",
        "bitwarden",
        "postman",
        "tableplus",
        "transmit",
        "forklift"
    ]

    private static func isLikelyAudioApp(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName ?? ""
        if nonAudioAppNames.contains(name) {
            return false
        }

        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        guard !bundle.isEmpty else { return true }

        for prefix in nonAudioBundleIDPrefixes where bundle == prefix || bundle.hasPrefix(prefix + ".") {
            return false
        }

        for fragment in nonAudioBundleIDFragments where bundle.contains(fragment) {
            return false
        }

        return true
    }
}

struct BiquadProcessor {
    var coefficients: BiquadCoefficients
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(coefficients: BiquadCoefficients) {
        self.coefficients = coefficients
    }

    mutating func process(_ input: Double) -> Double {
        let output = coefficients.b0 * input
            + coefficients.b1 * x1
            + coefficients.b2 * x2
            - coefficients.a1 * y1
            - coefficients.a2 * y2

        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}
