import Accelerate
import Foundation

struct AnalyzerSnapshot {
    var selectedChannel: AudioChannel
    var analyzerEnabled: Bool
    var analyzerMode: AnalyzerMode
    var leftBands: [ParametricBand]
    var rightBands: [ParametricBand]
    var inputLevelDB: Double

    var activeBands: [ParametricBand] {
        selectedChannel == .left ? leftBands : rightBands
    }
}

final class AnalyzerEngine: ObservableObject {
    @Published var spectrum: [SpectrumBin] = []
    @Published var curve: [CurvePoint] = []
    @Published var inputLevelDB = -22.0
    @Published var message = "Analyzer idle"

    private let sampleRate = 48_000.0
    private let fftSize = 512
    private let spectrumFrequencies: [Double]
    private let curveFrequencies: [Double]
    private let hannWindow: [Double]
    private let dftSetup: vDSP_DFT_SetupD
    private let analyzerQueue = DispatchQueue(label: "com.macEqualizer.analyzer", qos: .userInteractive)
    private var smoothedSpectrumMagnitudes: [Double] = []


    init() {
        let spectrumFrequencies = Self.logarithmicFrequencies(count: 84, minFrequency: 20, maxFrequency: 18_000)

        self.spectrumFrequencies = spectrumFrequencies
        self.curveFrequencies = Self.logarithmicFrequencies(count: 96, minFrequency: 20, maxFrequency: 20_000)
        var hann = [Double]()
        hann.reserveCapacity(fftSize)
        for index in 0..<fftSize {
            hann.append(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(fftSize - 1)))
        }
        self.hannWindow = hann
        self.dftSetup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(fftSize), vDSP_DFT_Direction.FORWARD)!
    }

    deinit {
        vDSP_DFT_DestroySetupD(dftSetup)
    }

    func tick(model: EqualizerModel) {
        guard model.analyzerEnabled, model.analyzerMode != .off else {
            if !message.isEmpty { message = "Analyzer paused" }
            if !spectrum.isEmpty { spectrum = [] }
            return
        }

        if spectrum.isEmpty && message != "Waiting for live audio" {
            message = "Waiting for live audio"
        }
    }

    func refresh(model: EqualizerModel) {
        scheduleAnalysis(with: snapshot(from: model))
    }

    func ingestLiveSamples(left: [Float], right: [Float], model: EqualizerModel) {
        guard model.analyzerEnabled, model.analyzerMode == .live else { return }

        let samples = model.selectedChannel == .left ? left.map(Double.init) : right.map(Double.init)
        let liveLevelDB = rmsDB(samples: samples)
        inputLevelDB += (liveLevelDB - inputLevelDB) * 0.2
        curve = makeCurve(for: model.activeBands, inputLevelDB: inputLevelDB)
        spectrum = smoothSpectrum(makeSpectrum(from: samples))
        message = "\(spectrum.count) live FFT bins at \(Int(sampleRate)) Hz"
    }

    func coefficients(for band: ParametricBand) -> BiquadCoefficients {
        guard band.isEnabled else { return .bypass }

        let frequency = min(max(band.frequency, 20), sampleRate * 0.45)
        let q = max(0.1, band.q)
        let gain = effectiveGain(for: band)
        let a = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)

        switch band.shape {
        case .peak:
            return normalize(
                b0: 1 + alpha * a,
                b1: -2 * cosOmega,
                b2: 1 - alpha * a,
                a0: 1 + alpha / a,
                a1: -2 * cosOmega,
                a2: 1 - alpha / a
            )
        case .lowShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: 2 * a * ((a - 1) - (a + 1) * cosOmega),
                b2: a * ((a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: -2 * ((a - 1) + (a + 1) * cosOmega),
                a2: (a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        case .highShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: -2 * a * ((a - 1) + (a + 1) * cosOmega),
                b2: a * ((a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: 2 * ((a - 1) - (a + 1) * cosOmega),
                a2: (a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        }
    }

    func effectiveGain(for band: ParametricBand) -> Double {
        guard band.isDynamic else { return band.gain }
        let overThreshold = max(0, inputLevelDB - band.threshold)
        let attenuation = overThreshold * (1 - 1 / max(1, band.ratio))
        if band.gain >= 0 {
            return max(0, band.gain - attenuation)
        }
        return min(0, band.gain + attenuation)
    }

    private func scheduleAnalysis(with snapshot: AnalyzerSnapshot) {

        guard snapshot.analyzerEnabled, snapshot.analyzerMode != .off else {
            spectrum = []
            curve = makeCurve(for: snapshot.activeBands, inputLevelDB: snapshot.inputLevelDB)
            message = "Analyzer paused"
            return
        }

        curve = makeCurve(for: snapshot.activeBands, inputLevelDB: snapshot.inputLevelDB)
        if spectrum.isEmpty {
            message = "Waiting for live audio"
        }
    }

    private func snapshot(from model: EqualizerModel) -> AnalyzerSnapshot {
        AnalyzerSnapshot(
            selectedChannel: model.selectedChannel,
            analyzerEnabled: model.analyzerEnabled,
            analyzerMode: model.analyzerMode,
            leftBands: model.leftBands,
            rightBands: model.rightBands,
            inputLevelDB: inputLevelDB
        )
    }

    private func makeCurve(for bands: [ParametricBand], inputLevelDB: Double) -> [CurvePoint] {
        curveFrequencies.map { frequency in
            let gain = bands.reduce(0.0) { partial, band in
                guard band.isEnabled else { return partial }
                let distance = abs(log2(frequency / band.frequency))
                let width = max(0.15, 1 / max(0.2, band.q))
                let contribution = effectiveGain(for: band, inputLevelDB: inputLevelDB) * exp(-pow(distance / width, 2))
                return partial + contribution
            }
            return CurvePoint(frequency: frequency, gain: min(max(gain, -18), 18))
        }
    }

    private func makeSpectrum(from samples: [Double]) -> [SpectrumBin] {
        var realInput = Array(repeating: 0.0, count: fftSize)
        var imaginaryInput = Array(repeating: 0.0, count: fftSize)
        var realOutput = Array(repeating: 0.0, count: fftSize)
        var imaginaryOutput = Array(repeating: 0.0, count: fftSize)

        samples.withUnsafeBufferPointer { samplesBuffer in
            hannWindow.withUnsafeBufferPointer { windowBuffer in
                realInput.withUnsafeMutableBufferPointer { outputBuffer in
                    vDSP_vmulD(
                        samplesBuffer.baseAddress!,
                        1,
                        windowBuffer.baseAddress!,
                        1,
                        outputBuffer.baseAddress!,
                        1,
                        vDSP_Length(fftSize)
                    )
                }
            }
        }

        vDSP_DFT_ExecuteD(dftSetup, &realInput, &imaginaryInput, &realOutput, &imaginaryOutput)

        return spectrumFrequencies.map { frequency in
            let magnitude = interpolatedMagnitude(
                at: frequency,
                realOutput: realOutput,
                imaginaryOutput: imaginaryOutput
            ) / Double(fftSize)
            return SpectrumBin(frequency: frequency, magnitude: min(1, magnitude * 18))
        }
    }

    private func interpolatedMagnitude(
        at frequency: Double,
        realOutput: [Double],
        imaginaryOutput: [Double]
    ) -> Double {
        let maxBin = fftSize / 2 - 1
        let binFloat = min(max(frequency / sampleRate * Double(fftSize), 0), Double(maxBin))
        let lower = Int(floor(binFloat))
        let upper = min(lower + 1, maxBin)
        let fraction = binFloat - Double(lower)

        let lowerMagnitude = hypot(realOutput[lower], imaginaryOutput[lower])
        let upperMagnitude = hypot(realOutput[upper], imaginaryOutput[upper])
        return lowerMagnitude + (upperMagnitude - lowerMagnitude) * fraction
    }

    private func rmsDB(samples: [Double]) -> Double {
        guard !samples.isEmpty else { return -96 }
        let meanSquare = samples.reduce(0.0) { $0 + $1 * $1 } / Double(samples.count)
        return 20 * log10(max(0.000_001, sqrt(meanSquare)))
    }

    private func smoothSpectrum(_ bins: [SpectrumBin]) -> [SpectrumBin] {
        if smoothedSpectrumMagnitudes.count != bins.count {
            smoothedSpectrumMagnitudes = bins.map(\.magnitude)
            return bins
        }

        var result: [SpectrumBin] = []
        result.reserveCapacity(bins.count)

        for (index, bin) in bins.enumerated() {
            let previous = smoothedSpectrumMagnitudes[index]
            let alpha = bin.magnitude > previous ? 0.35 : 0.14
            let smoothed = previous + (bin.magnitude - previous) * alpha
            smoothedSpectrumMagnitudes[index] = smoothed
            result.append(SpectrumBin(frequency: bin.frequency, magnitude: smoothed))
        }

        return result
    }

    private func coefficients(for band: ParametricBand, inputLevelDB: Double) -> BiquadCoefficients {
        guard band.isEnabled else { return .bypass }

        let frequency = min(max(band.frequency, 20), sampleRate * 0.45)
        let q = max(0.1, band.q)
        let gain = effectiveGain(for: band, inputLevelDB: inputLevelDB)
        let a = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)

        switch band.shape {
        case .peak:
            return normalize(
                b0: 1 + alpha * a,
                b1: -2 * cosOmega,
                b2: 1 - alpha * a,
                a0: 1 + alpha / a,
                a1: -2 * cosOmega,
                a2: 1 - alpha / a
            )
        case .lowShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: 2 * a * ((a - 1) - (a + 1) * cosOmega),
                b2: a * ((a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: -2 * ((a - 1) + (a + 1) * cosOmega),
                a2: (a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        case .highShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: -2 * a * ((a - 1) + (a + 1) * cosOmega),
                b2: a * ((a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: 2 * ((a - 1) - (a + 1) * cosOmega),
                a2: (a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        }
    }

    private func effectiveGain(for band: ParametricBand, inputLevelDB: Double) -> Double {
        guard band.isDynamic else { return band.gain }
        let overThreshold = max(0, inputLevelDB - band.threshold)
        let attenuation = overThreshold * (1 - 1 / max(1, band.ratio))
        if band.gain >= 0 {
            return max(0, band.gain - attenuation)
        }
        return min(0, band.gain + attenuation)
    }

    private func normalize(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        guard a0 != 0 else { return .bypass }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func logarithmicFrequencies(count: Int, minFrequency: Double, maxFrequency: Double) -> [Double] {
        let minLog = log10(minFrequency)
        let maxLog = log10(maxFrequency)
        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            return pow(10, minLog + (maxLog - minLog) * progress)
        }
    }
}
