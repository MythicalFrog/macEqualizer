import AppKit
import Foundation
import MediaRemoteAdapter

struct TrackInfo: Equatable {
    let title: String
    let artist: String
    let album: String
    var sourceApp: String = ""

    var cacheKey: String {
        "\(title.lowercased().trimmingCharacters(in: .whitespaces))|\(artist.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}

final class NowPlayingService: ObservableObject {
    @Published var currentTrackInfo: TrackInfo?

    private let mediaController = MediaController()
    private var lastKey: String = ""
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSwitchTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 4.0

    private var appleScriptTimer: Timer?
    private var fallbackMode = false

    @MainActor
    func start() {
        mediaController.onTrackInfoReceived = { [weak self] remoteInfo in
            self?.handleRemoteTrackInfo(remoteInfo)
        }
        mediaController.onListenerTerminated = { [weak self] in
            DispatchQueue.main.async {
                self?.enableAppleScriptFallback()
            }
        }
        mediaController.startListening()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.currentTrackInfo == nil && !self.fallbackMode {
                self.enableAppleScriptFallback()
            }
        }
    }

    @MainActor
    func stop() {
        mediaController.stopListening()
        appleScriptTimer?.invalidate()
        appleScriptTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - MediaRemote (primary)

    private func handleRemoteTrackInfo(_ remoteInfo: MediaRemoteAdapter.TrackInfo?) {
        guard let remoteInfo = remoteInfo else {
            debouncedUpdate(nil)
            return
        }

        let payload = remoteInfo.payload
        guard let title = payload.title, !title.isEmpty else {
            debouncedUpdate(nil)
            return
        }
        let artist = payload.artist ?? "Unknown Artist"
        let album = payload.album ?? ""
        let sourceApp = payload.applicationName ?? payload.bundleIdentifier ?? ""

        let track = TrackInfo(title: title, artist: artist, album: album, sourceApp: sourceApp)
        debouncedUpdate(track)
    }

    // MARK: - Debounce / cooldown

    private func debouncedUpdate(_ track: TrackInfo?) {
        debounceWorkItem?.cancel()

        if let track = track {
            let key = track.cacheKey
            guard key != lastKey else { return }

            let now = Date()
            let elapsed = now.timeIntervalSince(lastSwitchTime)
            let delay = max(0, cooldownSeconds - elapsed)

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastKey = key
                self.lastSwitchTime = Date()
                DispatchQueue.main.async {
                    self.currentTrackInfo = track
                }
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else if currentTrackInfo != nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastKey = ""
                DispatchQueue.main.async {
                    self.currentTrackInfo = nil
                }
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
        }
    }

    // MARK: - AppleScript fallback

    private func enableAppleScriptFallback() {
        guard !fallbackMode else { return }
        fallbackMode = true
        mediaController.stopListening()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.checkAppleScriptNowPlaying()
            self.appleScriptTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkAppleScriptNowPlaying()
            }
        }
    }

    private func checkAppleScriptNowPlaying() {
        if let track = getTrackFromSpotify() ?? getTrackFromMusic() ?? getTrackFromDynamicApps() {
            let key = track.cacheKey
            guard key != lastKey else { return }
            lastKey = key
            currentTrackInfo = track
        } else if currentTrackInfo != nil {
            currentTrackInfo = nil
            lastKey = ""
        }
    }

    private func getTrackFromSpotify() -> TrackInfo? {
        let script = """
        tell application "Spotify"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                return trackName & "|" & artistName & "|" & albumName
            end if
        end tell
        """
        return runAppleScript(script, sourceApp: "Spotify")
    }

    private func getTrackFromMusic() -> TrackInfo? {
        let script = """
        tell application "Music"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                return trackName & "|" & artistName & "|" & albumName
            end if
        end tell
        """
        return runAppleScript(script, sourceApp: "Music")
    }

    private func getTrackFromDynamicApps() -> TrackInfo? {
        let candidates: [(String, String)] = [
            ("YouTube Music", "YouTube Music"),
            ("VLC", "VLC"),
            ("IINA", "IINA"),
            ("Spotify", "Spotify"),
            ("Music", "Music"),
        ]

        let runningNames = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.localizedName })

        for (appName, _) in candidates {
            guard runningNames.contains(appName) else { continue }
            if let track = queryAppleScript(app: appName) {
                return track
            }
        }
        return nil
    }

    private func queryAppleScript(app: String) -> TrackInfo? {
        switch app {
        case "Spotify":
            return getTrackFromSpotify()
        case "Music":
            return getTrackFromMusic()
        case "YouTube Music":
            return runAppleScript("""
            tell application "YouTube Music"
                if player state is playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    return trackName & "|" & artistName & "|" & albumName
                end if
            end tell
            """, sourceApp: "YouTube Music")
        case "VLC":
            return runAppleScript("""
            tell application "VLC"
                if playing then
                    set trackName to name of current item
                    set artistName to artist of current item
                    set albumName to album of current item
                    return trackName & "|" & artistName & "|" & albumName
                end if
            end tell
            """, sourceApp: "VLC")
        case "IINA":
            return runAppleScript("""
            tell application "IINA"
                if playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    return trackName & "|" & artistName & "|" & albumName
                end if
            end tell
            """, sourceApp: "IINA")
        default:
            return nil
        }
    }

    private func runAppleScript(_ script: String, sourceApp: String) -> TrackInfo? {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        guard let stringValue = result?.stringValue, !stringValue.isEmpty else {
            return nil
        }

        let parts = stringValue.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        return TrackInfo(title: title, artist: artist, album: album, sourceApp: sourceApp)
    }

    deinit {
        mediaController.stopListening()
        appleScriptTimer?.invalidate()
        debounceWorkItem?.cancel()
    }
}
