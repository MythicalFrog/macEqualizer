import AppKit

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

    private var lastKey: String = ""
    private var pollTimer: Timer?

    @MainActor
    func start() {
        guard pollTimer == nil else { return }
        checkNowPlaying()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkNowPlaying()
        }
    }

    @MainActor
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastKey = ""
        currentTrackInfo = nil
    }

    private func checkNowPlaying() {
        let track = getFromSystemNowPlaying() ?? getFromAppleScript()
        if let track = track {
            let key = track.cacheKey
            guard key != lastKey else { return }
            lastKey = key
            currentTrackInfo = track
            log("detected: \(track.title) - \(track.artist) via \(track.sourceApp)")
        } else if currentTrackInfo != nil {
            currentTrackInfo = nil
            lastKey = ""
            log("track cleared")
        }
    }

    // MARK: - System Now Playing (works for Safari, Chrome, Spotify, Music, etc.)

    private func getFromSystemNowPlaying() -> TrackInfo? {
        guard let cliPath = findCLI() else {
            log("nowplaying-cli not found")
            return nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = ["get", "title", "artist", "album"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) == nil else {
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parseCLIOutput(output)
        }
        return nil
    }

    private func parseCLIOutput(_ output: String) -> TrackInfo? {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty else { return nil }

        let title = lines[0]
        let artist = lines.count >= 2 ? lines[1] : "Unknown Artist"
        let album = lines.count >= 3 ? lines[2] : ""

        return TrackInfo(title: title, artist: artist, album: album, sourceApp: "Now Playing")
    }

    private func findCLI() -> String? {
        let paths = [
            "/opt/homebrew/bin/nowplaying-cli",
            "/usr/local/bin/nowplaying-cli",
            "/usr/bin/nowplaying-cli"
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func log(_ msg: String) {
        let line = "[NowPlaying] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let handle = FileHandle(forWritingAtPath: "/tmp/maceq_debug.log")
            handle?.seekToEndOfFile()
            handle?.write(data)
            handle?.closeFile()
        }
    }

    // MARK: - AppleScript fallback (for apps that don't report to system center)

    private func getFromAppleScript() -> TrackInfo? {
        return getFromSpotify() ?? getFromMusic() ?? getFromYouTubeMusic() ?? getFromVLC()
    }

    private func getFromSpotify() -> TrackInfo? {
        guard isAppRunning("Spotify") else { return nil }
        return runAppleScript("""
        tell application "Spotify"
            if player state is playing then
                return name of current track & "|" & artist of current track & "|" & album of current track
            end if
        end tell
        """, sourceApp: "Spotify")
    }

    private func getFromMusic() -> TrackInfo? {
        guard isAppRunning("Music") else { return nil }
        return runAppleScript("""
        tell application "Music"
            if player state is playing then
                return name of current track & "|" & artist of current track & "|" & album of current track
            end if
        end tell
        """, sourceApp: "Music")
    }

    private func getFromYouTubeMusic() -> TrackInfo? {
        guard isAppRunning("YouTube Music") else { return nil }
        return runAppleScript("""
        tell application "YouTube Music"
            if player state is playing then
                return name of current track & "|" & artist of current track & "|" & album of current track
            end if
        end tell
        """, sourceApp: "YouTube Music")
    }

    private func getFromVLC() -> TrackInfo? {
        guard isAppRunning("VLC") else { return nil }
        return runAppleScript("""
        tell application "VLC"
            if playing then
                return name of current item & "|" & artist of current item & "|" & album of current item
            end if
        end tell
        """, sourceApp: "VLC")
    }

    // MARK: - Helpers

    private func isAppRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private func runAppleScript(_ script: String, sourceApp: String) -> TrackInfo? {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        guard error == nil,
              let value = result?.stringValue,
              !value.isEmpty else { return nil }

        let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }

        return TrackInfo(
            title: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            artist: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : "",
            sourceApp: sourceApp
        )
    }

    deinit {
        pollTimer?.invalidate()
    }
}
