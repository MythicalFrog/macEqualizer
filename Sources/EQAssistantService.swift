import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    let content: String

    enum MessageRole: String {
        case user
        case assistant
    }
}

enum EQError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case parseError
    case noCSVFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let message):
            if !message.isEmpty { return "\(message)" }
            return "HTTP error \(code)"
        case .parseError: return "Failed to parse response"
        case .noCSVFound: return "No CSV data in response"
        }
    }
}

@MainActor
final class EQAssistantService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var lastError = ""
    @Published var lastGeneratedCSV = ""

    private let apiKey: String = Secrets.geminiAPIKey
    private let model = "gemini-3.1-flash-lite"

    private let systemInstruction: String = {
        """
        You are a professional audio EQ engineer. Generate parametric EQ bands to enhance the user's listening experience.

        Return the CSV using this format with exactly 6 columns per line:
        frequency,gain,q,is_dynamic,threshold,ratio

        Detailed column descriptions:
        - frequency (20 to 20,000): The center frequency of the band in Hz. Low frequencies (20-250 Hz) affect bass/rumble, mids (250-4000 Hz) affect body/presence, highs (4000-20,000 Hz) affect air/detail/sibilance. Choose frequencies that target the specific tonal area the user describes.
        - gain (-18 to +18): Boost or cut in dB. Be deliberate and confident — aim for gains that produce a clearly audible difference. Typical boosts should be +4 to +8 dB, typical cuts -3 to -6 dB. Anything under ±2 dB is too subtle to notice. Don't be timid with the gain values.
        - q (0.3 to 10.0): The bandwidth/resonance of the filter. Low Q (< 1) affects a wide range (broad/smooth), high Q (> 3) affects a narrow range (precise/surgical). Use high Q for targeting specific problem frequencies, low Q for gentle tonal shaping.
        - is_dynamic (0 or 1): Set to 1 when the band should function as a compressor — reducing gain only when the input signal crosses a threshold. Use for taming peaks, harshness, or volume spikes. Set to 0 for standard static EQ.
        - threshold (-36 to 0): The input level in dB at which dynamic gain reduction begins. Only meaningful when is_dynamic=1. A lower threshold (e.g. -30) means the compressor engages sooner. A higher threshold (e.g. -12) means it only engages on loud peaks. For is_dynamic=0, set to 0.
        - ratio (1.5 to 6.0): The compression ratio for dynamic bands. A ratio of 3:1 means the output increases by 1 dB for every 3 dB input above threshold. Higher ratios (4:1 to 6:1) provide stronger limiting. Lower ratios (1.5:1 to 3:1) provide gentle compression. For is_dynamic=0, set to 0.

        Strategy guidance:
        - Be deliberate and confident. Make each band do something clearly audible. A boost should be big enough to hear the difference. A cut should be deep enough to solve the problem.
        - Focus on ENHANCEMENT: bold boosts for tonal balance, air, warmth, presence. Think +5 dB bass shelf, +6 dB presence, +4 dB air — not +1 dB nips.
        - Use dynamic bands (is_dynamic=1) for frequencies that need compression only at high volumes — choose the band placement based on what the song actually needs. Heavy bass music may need dynamic control in the low end (60-200 Hz). Harsh cymbals or synths may need it in the highs (6-12 kHz). Vocals may need it in the mids (1-4 kHz). Do NOT always place dynamic bands in the same frequency range — vary them per song.
        - Use static bands (is_dynamic=0) for consistent tonal shaping like bass warmth, presence boost, or air.
        - Space bands evenly across the frequency spectrum rather than clustering them.
        - Vary the total number of dynamic bands per song: some songs need 1, others need 3-4. Not every song needs the same count.

        Rules:
        - 6–10 bands
        - Peak filters only
        - ALWAYS output all 6 columns per line. For non-dynamic bands set is_dynamic=0, threshold=0, ratio=0.
        - Do NOT include a header row. Return ONLY the CSV code block, no explanations.

        Examples:
        "bass boost" → 60,8.0,0.8,0,0,0 / 120,5.0,0.6,0,0,0 / 8000,3.0,1.2,0,0,0
        "bright vocals" → 200,-4.0,0.7,0,0,0 / 3200,6.5,1.4,1,-20,2.8 / 8000,5.0,0.9,0,0,0
        "compressed radio" → 80,6.0,0.6,1,-24,3.0 / 250,-3.0,0.8,0,0,0 / 2000,-5.0,1.0,1,-18,4.0 / 8000,5.0,0.8,0,0,0
        "heavy metal" → 80,7.0,0.7,0,0,0 / 250,-5.0,1.2,0,0,0 / 3500,5.0,2.0,1,-22,3.5 / 6500,-6.0,3.0,1,-18,4.0 / 12000,4.0,0.8,0,0,0
        "lo-fi hip hop" → 100,7.0,0.6,1,-28,2.0 / 400,4.0,0.9,0,0,0 / 3000,-4.0,1.5,0,0,0 / 8000,3.0,1.0,0,0,0
        "classical orchestra" → 60,4.0,0.5,0,0,0 / 500,3.5,0.8,0,0,0 / 2500,-4.0,2.0,1,-20,2.5 / 5000,4.0,1.2,0,0,0 / 10000,5.0,0.7,1,-16,3.0 / 16000,3.0,0.6,0,0,0
        """
    }()

    func sendMessage(_ text: String, model: EqualizerModel) async {
        guard apiKey != "your_api_key_here", !apiKey.isEmpty else {
            lastError = "Gemini API key not configured"
            return
        }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        isLoading = true
        lastError = ""

        do {
            let csv = try await callGemini(prompt: text)
            let cleaned = csv.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw EQError.noCSVFound
            }
            lastGeneratedCSV = cleaned
            messages.append(ChatMessage(role: .assistant, content: cleaned))
            model.parseAutoEQCSV(cleaned)
        } catch let error as EQError {
            let msg = error.errorDescription ?? error.localizedDescription
            lastError = msg
            messages.append(ChatMessage(role: .assistant, content: "Error: \(msg)"))
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
        }

        isLoading = false
    }

    func fetchEQCSV(for track: TrackInfo) async -> String? {
        let prompt = "Generate 6-10 parametric EQ bands (6-column CSV: frequency,gain,q,is_dynamic,threshold,ratio, no header) tailored to the specific song: \"\(track.title)\" by \(track.artist). Consider the genre, instrumentation, and likely frequency characteristics of this song. frequency=center frequency in Hz (20-20000), gain=dB boost/cut (-18 to +18), q=bandwidth/resonance (0.3-10.0, lower=broader), is_dynamic=0 for static or 1 for dynamic compression-style band, threshold=input level in dB (-36 to 0, for dynamic bands only, set 0 if not dynamic), ratio=compression ratio (1.5-6.0, for dynamic bands only, set 0 if not dynamic). Vary dynamic band placement based on what this particular song needs — do not always use the same frequency ranges. Return ONLY the CSV block."
        do {
            return try await callGemini(prompt: prompt)
        } catch {
            return nil
        }
    }

    private func callGemini(prompt: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.6,
                "maxOutputTokens": 1024
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EQError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = extractErrorMessage(from: data)
            throw EQError.httpError(httpResponse.statusCode, errorMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw EQError.parseError
        }

        return try extractCSV(from: text)
    }

    private func extractErrorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return ""
        }
        return message
    }

    private func extractCSV(from text: String) throws -> String {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        if let match = try? NSRegularExpression(pattern: "```csv\\s*\\n(.*?)```", options: [.dotMatchesLineSeparators])
            .firstMatch(in: text, options: [], range: range) {
            let csvRange = match.range(at: 1)
            guard csvRange.location != NSNotFound else { throw EQError.noCSVFound }
            return nsText.substring(with: csvRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = text.components(separatedBy: .newlines)
            .filter { line in
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count >= 3
                    && Double(parts[0]) != nil
                    && Double(parts[1]) != nil
                    && Double(parts[2]) != nil
            }

        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }

        throw EQError.noCSVFound
    }
}
