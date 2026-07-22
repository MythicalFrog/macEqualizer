import AppKit
import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @StateObject private var analyzer = AnalyzerEngine()
    @StateObject private var systemAudio = SystemAudioEngine()
    @State private var csvText = "50,-2.0,0.8\n220,-1.4,1.1\n1800,2.2,1.0\n6200,-2.8,2.4"
    private let analyzerTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let appScanTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBar()
                AnalyzerPanel()
                NodeWorkspace()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    SystemAudioPanel()
                    RoutingMatrixPanel()
                    PluginPipelinePanel()
                    EQAssistantPanel(csvText: $csvText)
                    AutoEQPanel()
                    HeadphonePresetsPanel(csvText: $csvText)
                    ConditionPresetPanel()
                }
            }
            .padding(20)
        }
        .background(StudioBackground())
        .environmentObject(analyzer)
        .environmentObject(systemAudio)
        .preferredColorScheme(.dark)
        .onReceive(analyzerTimer) { _ in
            analyzer.tick(model: model)
        }
        .onReceive(appScanTimer) { _ in
            model.scanRunningApplications()
        }
        .onChange(of: model.leftBands) { _ in
            model.bindChannelsFromLeftIfNeeded()
            analyzer.refresh(model: model)
            systemAudio.updateBands(model: model)
        }
        .onChange(of: model.rightBands) { _ in
            analyzer.refresh(model: model)
            systemAudio.updateBands(model: model)
        }
        .onChange(of: model.selectedChannel) { _ in
            analyzer.refresh(model: model)
        }
        .onChange(of: model.analyzerMode) { _ in
            analyzer.refresh(model: model)
        }
        .onChange(of: model.routes) { _ in
            model.syncAllRouteVolumes()
        }
        .onAppear {
            model.scanRunningApplications()
            model.syncAllRouteVolumes()
            systemAudio.monitor = { left, right in
                analyzer.ingestLiveSamples(left: left, right: right, model: model)
            }
            analyzer.refresh(model: model)
            systemAudio.updateBands(model: model)
        }
        .onChange(of: model.isAutoEQEnabled) { enabled in
            if enabled {
                nowPlaying.start()
            } else {
                nowPlaying.stop()
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var analyzer: AnalyzerEngine
    @EnvironmentObject private var systemAudio: SystemAudioEngine

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("macEqualizer")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Advanced system audio control surface")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            MetricPill(title: "Preset", value: model.activePreset.rawValue)
            MetricPill(title: "Routes", value: "\(model.activeRouteCount)")
            MetricPill(title: "Plugins", value: "\(model.enabledPluginCount)")
            MetricPill(title: "Input", value: String(format: "%.1f dB", analyzer.inputLevelDB))
            MetricPill(title: "System", value: systemAudio.mode.rawValue)
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(surface1, in: Capsule())
        .overlay(Capsule().stroke(glassBorder))
    }
}

struct AnalyzerPanel: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var analyzer: AnalyzerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Channel", selection: $model.selectedChannel) {
                    ForEach(AudioChannel.allCases) { channel in
                        Text(channel.rawValue).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                PillToggle(isOn: $model.linkChannels)

                PillToggle(isOn: $model.analyzerEnabled)

                Picker("Analyzer", selection: $model.analyzerMode) {
                    ForEach(AnalyzerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                Text(analyzer.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            EQCurveCanvas()
                .frame(height: 300)
        }
        .panelStyle()
    }
}

struct EQCurveCanvas: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var analyzer: AnalyzerEngine

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGrid(in: rect, context: &context)
            drawSpectrum(in: rect, context: &context)
            drawZeroLine(in: rect, context: &context)
            drawCurve(in: rect, context: &context)
            drawNodes(in: rect, context: &context)
        }
        .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
    }

    private func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
        let gridColor = Color.white.opacity(0.08)
        let labelColor = Color.white.opacity(0.45)
        let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)

        for gain in stride(from: -18.0, through: 18.0, by: 6.0) {
            var path = Path()
            let y = yPosition(forGain: gain, in: rect)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: gain == 0 ? 1.2 : 0.7)

            let label = gain == 0 ? "0" : "\(Int(gain))"
            let text = Text(label).font(labelFont).foregroundColor(labelColor)
            context.draw(text, at: CGPoint(x: rect.minX + 2, y: y - 7), anchor: .topLeading)
        }

        let freqLabels: [(Double, String)] = [
            (20, "20"), (50, "50"), (100, "100"), (250, "250"),
            (500, "500"), (1000, "1k"), (2500, "2.5k"), (5000, "5k"),
            (10_000, "10k"), (20_000, "20k")
        ]
        for (freq, label) in freqLabels {
            var path = Path()
            let x = xPosition(forFrequency: freq, in: rect)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.7)

            let text = Text(label).font(labelFont).foregroundColor(labelColor)
            context.draw(text, at: CGPoint(x: x, y: rect.maxY - 2), anchor: .bottom)
        }
    }

    private func drawSpectrum(in rect: CGRect, context: inout GraphicsContext) {
        guard model.analyzerEnabled else { return }
        for bin in analyzer.spectrum {
            let x = xPosition(forFrequency: bin.frequency, in: rect)
            let width = max(2, rect.width / CGFloat(max(analyzer.spectrum.count, 1)) * 0.8)
            let height = rect.height * CGFloat(bin.magnitude) * 0.58
            let bar = CGRect(x: x - width / 2, y: rect.maxY - height, width: width, height: height)
            context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(accent.opacity(0.28)))
        }
    }

    private func drawZeroLine(in rect: CGRect, context: inout GraphicsContext) {
        var path = Path()
        let y = yPosition(forGain: 0, in: rect)
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1.4)
    }

    private func drawCurve(in rect: CGRect, context: inout GraphicsContext) {
        guard let first = analyzer.curve.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: xPosition(forFrequency: first.frequency, in: rect), y: yPosition(forGain: first.gain, in: rect)))

        for point in analyzer.curve.dropFirst() {
            path.addLine(to: CGPoint(x: xPosition(forFrequency: point.frequency, in: rect), y: yPosition(forGain: point.gain, in: rect)))
        }

        context.stroke(path, with: .color(accent), lineWidth: 3)
    }

    private func drawNodes(in rect: CGRect, context: inout GraphicsContext) {
        for band in model.activeBands where band.isEnabled {
            let point = CGPoint(
                x: xPosition(forFrequency: band.frequency, in: rect),
                y: yPosition(forGain: analyzer.effectiveGain(for: band), in: rect)
            )
            let nodeRect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: nodeRect), with: .color(band.isDynamic ? .orange : accent))
            context.stroke(Path(ellipseIn: nodeRect.insetBy(dx: -2, dy: -2)), with: .color(.white.opacity(0.52)), lineWidth: 1)
        }
    }

    private func xPosition(forFrequency frequency: Double, in rect: CGRect) -> CGFloat {
        let minLog = log10(20.0)
        let maxLog = log10(20_000.0)
        let value = (log10(max(20, min(20_000, frequency))) - minLog) / (maxLog - minLog)
        return rect.minX + rect.width * CGFloat(value)
    }

    private func yPosition(forGain gain: Double, in rect: CGRect) -> CGFloat {
        let clamped = max(-18, min(18, gain))
        let normalized = (clamped + 18) / 36
        return rect.maxY - rect.height * CGFloat(normalized)
    }
}

struct NodeWorkspace: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Parametric Nodes")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    model.addBand()
                } label: {
                    Text("Add Node")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(accent.opacity(0.12), in: Capsule())

                Button {
                    model.copyLeftToRight()
                } label: {
                    Image(systemName: "arrow.right.to.line.compact")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy left curve to right")

                Button {
                    model.copyRightToLeft()
                } label: {
                    Image(systemName: "arrow.left.to.line.compact")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy right curve to left")
            }

            if model.selectedChannel == .left {
                BandEditor(bands: $model.leftBands)
            } else {
                BandEditor(bands: $model.rightBands)
            }
        }
        .panelStyle()
    }
}

struct BandEditor: View {
    @Binding var bands: [ParametricBand]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach($bands) { $band in
                    BandCard(band: $band) {
                        bands.removeAll { $0.id == band.id }
                    }
                    .frame(width: 214)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct BandCard: View {
    @EnvironmentObject private var analyzer: AnalyzerEngine
    @Binding var band: ParametricBand
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Node", text: $band.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 40)
                Spacer(minLength: 0)
                PillToggle(isOn: $band.isEnabled)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete node")
            }

            HStack(alignment: .bottom, spacing: 12) {
                VerticalFrequencyFader(band: $band)
                VerticalGainFader(band: $band)
                VStack(spacing: 8) {
                    Picker("Shape", selection: $band.shape) {
                        ForEach(FilterShape.allCases) { shape in
                            Text(shape.rawValue).tag(shape)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Q")
                                .foregroundStyle(.secondary)
                            Text("\(band.q, specifier: "%.1f")")
                        }
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        Slider(value: $band.q, in: 0.3...10, step: 0.1)
                            .controlSize(.small)
                    }

                    Toggle("Dynamic", isOn: $band.isDynamic)
                        .font(.caption)

                    if band.isDynamic {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Thresh")
                                    .foregroundStyle(.secondary)
                                Text("\(band.threshold, specifier: "%.0f")dB")
                            }
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            Slider(value: $band.threshold, in: -48...0, step: 1)
                                .controlSize(.small)
                            HStack {
                                Text("Ratio")
                                    .foregroundStyle(.secondary)
                                Text("\(band.ratio, specifier: "%.1f"):1")
                            }
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            Slider(value: $band.ratio, in: 1...8, step: 0.1)
                                .controlSize(.small)
                        }
                    }
                }
            }

            CoefficientReadout(coefficients: analyzer.coefficients(for: band), effectiveGain: analyzer.effectiveGain(for: band))
        }
        .padding(10)
        .background(surface1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(band.isDynamic ? .orange.opacity(0.25) : glassBorder))
    }
}

struct VerticalFrequencyFader: View {
    @Binding var band: ParametricBand

    var body: some View {
        VerticalDragFader(
            title: "Freq",
            valueText: band.displayFrequency,
            value: Binding(
                get: { log10(max(20, min(20_000, band.frequency))) },
                set: { band.frequency = pow(10, $0) }
            ),
            range: log10(20.0)...log10(20_000.0),
            step: 0.002,
            tint: .cyan
        )
    }
}

struct VerticalGainFader: View {
    @Binding var band: ParametricBand

    var body: some View {
        VerticalDragFader(
            title: "Gain",
            valueText: String(format: "%.1f dB", band.gain),
            value: $band.gain,
            range: -18...18,
            step: 0.1,
            tint: .orange
        )
    }
}

struct VerticalDragFader: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(valueText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, height: 14)

            GeometryReader { geometry in
                let trackWidth: CGFloat = 6
                let knobSize: CGFloat = 18
                let fillHeight = geometry.size.height * progress
                let knobY = geometry.size.height * (1 - progress)

                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(.black.opacity(0.35))
                        .frame(width: trackWidth)

                    Capsule()
                        .fill(tint.opacity(0.72))
                        .frame(width: trackWidth, height: max(trackWidth, fillHeight))

                    Circle()
                        .fill(tint)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: tint.opacity(0.45), radius: 4)
                        .position(x: geometry.size.width / 2, y: knobY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            setValue(from: gesture.location.y, height: geometry.size.height)
                        }
                )
            }
            .frame(width: 52, height: 150)

            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 52)
    }

    private var progress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    private func setValue(from yPosition: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        let rawProgress = Double(1 - (yPosition / height).clamped(to: 0...1))
        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * rawProgress
        let steppedValue = (rawValue / step).rounded() * step
        value = min(max(steppedValue, range.lowerBound), range.upperBound)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct CoefficientReadout: View {
    let coefficients: BiquadCoefficients
    let effectiveGain: Double

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
            GridRow {
                Text("eff").foregroundStyle(.secondary)
                Text("\(effectiveGain, specifier: "%.2f")")
            }
            GridRow {
                Text("b0").foregroundStyle(.secondary)
                Text("\(coefficients.b0, specifier: "%.3f")")
            }
            GridRow {
                Text("b1").foregroundStyle(.secondary)
                Text("\(coefficients.b1, specifier: "%.3f")")
            }
            GridRow {
                Text("b2").foregroundStyle(.secondary)
                Text("\(coefficients.b2, specifier: "%.3f")")
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface2, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct RoutingMatrixPanel: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Application Routing", systemImage: "point.3.connected.trianglepath.dotted")

            ForEach($model.routes) { $route in
                RoutingRow(route: $route)
            }

        }
        .panelStyle()
    }
}

struct RoutingRow: View {
    @EnvironmentObject private var model: EqualizerModel
    @Binding var route: AppRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AppRouteIcon(pid: route.pid)
                Text(route.appName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                Text("PID \(route.pid)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                PillToggle(isOn: $route.effectsEnabled)
                    .onChange(of: route.effectsEnabled) { _ in
                        model.syncAppVolume(for: route.id)
                    }
            }

            HStack {
                Slider(value: $route.volume, in: 0...1)
                    .tint(accent)
                    .onChange(of: route.volume) { _ in
                        model.syncAppVolume(for: route.id)
                    }
                Text("\(Int(route.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                    .lineLimit(1)
            }

            HStack {
                Picker("Preset", selection: $route.preset) {
                    ForEach(RoutePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                PillToggle(isOn: $route.pluginsEnabled)
            }
        }
        .padding(10)
        .background(surface1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(glassBorder))
    }
}

struct AppRouteIcon: View {
    let pid: Int

    private var icon: NSImage? {
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let appIcon = app.icon else {
            return nil
        }
        return appIcon
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SystemAudioPanel: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var systemAudio: SystemAudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle("System Audio", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                Circle()
                    .fill(systemAudio.isRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
            }

            Text(systemAudio.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !systemAudio.lastError.isEmpty {
                Text(systemAudio.lastError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    if systemAudio.isRunning {
                        systemAudio.stop()
                    } else {
                        systemAudio.start(model: model)
                    }
                } label: {
                    Text(systemAudio.isRunning ? "Stop" : "Start")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(accent.opacity(0.12), in: Capsule())

                Button {
                    systemAudio.updateBands(model: model)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!systemAudio.isRunning)
                .help("Sync EQ")

                Button {
                    systemAudio.runSelfTest()
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Self-Test")
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Captured").foregroundStyle(.secondary)
                    Text("\(systemAudio.framesCaptured)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Underruns").foregroundStyle(.secondary)
                    Text("\(systemAudio.underruns)")
                        .monospacedDigit()
                }
            }
            .font(.caption)

            if !systemAudio.diagnosticsReport.isEmpty {
                Text(systemAudio.diagnosticsReport)
                    .font(.caption2.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface2, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .panelStyle()
    }
}

struct PluginPipelinePanel: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle("Plugin Pipeline", systemImage: "puzzlepiece.extension")
                Spacer()
                Button {
                    model.addPluginSlot()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add plugin slot")
            }

            ForEach($model.pluginChain) { $slot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Plugin", text: $slot.name)
                            .textFieldStyle(.plain)
                            .font(.headline)
                        Spacer()
                        Text(slot.format)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                        PillToggle(isOn: $slot.isEnabled)
                    }

                    HStack {
                        Text("Wet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $slot.wetMix, in: 0...1)
                            .tint(accent)
                        Text("\(Int(slot.wetMix * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }

                    HStack {
                        Text("Latency")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $slot.latencyMS, in: 0...30, step: 0.1)
                            .tint(accent)
                        Text("\(slot.latencyMS, specifier: "%.1f") ms")
                            .font(.caption.monospacedDigit())
                            .frame(width: 68, alignment: .trailing)
                    }

                    TextField("Serialized state", text: $slot.serializedState)
                        .font(.caption.monospaced())
                }
                .padding(10)
                .background(surface1, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .panelStyle()
    }
}

struct AutoEQPanel: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var assistant: EQAssistantService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Auto-EQ", systemImage: "waveform.badge.mic")

            HStack {
                PillToggle(isOn: $model.isAutoEQEnabled)
                Text(model.isAutoEQEnabled ? "On" : "Off")
                    .font(.caption)
                    .foregroundStyle(model.isAutoEQEnabled ? accent : .secondary)
                Spacer()
                if model.isAutoEQApplying {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
            }

            if let track = nowPlaying.currentTrackInfo {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !track.sourceApp.isEmpty {
                        Text(track.sourceApp)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(surface1, in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                    Text("No track playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(surface1, in: RoundedRectangle(cornerRadius: 8))
            }

            if !model.autoEQStatus.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.autoEQStatus == "applied" ? accent : model.autoEQStatus == "error" ? .orange : .secondary)
                        .frame(width: 6, height: 6)
                    Text(model.autoEQStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("Generates EQ per song via Gemini based on what's playing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
        .onReceive(nowPlaying.$currentTrackInfo) { track in
            guard model.isAutoEQEnabled, let track = track else { return }
            model.autoEQTrack(track, assistant: assistant)
        }
    }
}

struct HeadphonePresetsPanel: View {
    @EnvironmentObject private var model: EqualizerModel
    @Binding var csvText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Headphone Presets", systemImage: "headphones")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search headphones, IEMs...", text: $model.autoEqSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { model.searchAutoEq() }
                if !model.autoEqSearchQuery.isEmpty {
                    Button { model.autoEqSearchQuery = ""; model.autoEqSearchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(surface1, in: RoundedRectangle(cornerRadius: 8))

            if !model.autoEqSearchStatus.isEmpty {
                Text(model.autoEqSearchStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !model.autoEqSearchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.autoEqSearchResults) { result in
                            Button {
                                model.applyAutoEqProfile(at: result.path)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(result.displayName)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        if !result.source.isEmpty {
                                            Text(result.source)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(accent)
                                }
                                .padding(8)
                                .background(surface1, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            Divider().overlay(glassBorder)

            HStack(spacing: 10) {
                Button {
                    model.parseAutoEQCSV(csvText)
                } label: {
                    Text("Parse CSV")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(accent.opacity(0.12), in: Capsule())
            }

            TextEditor(text: $csvText)
                .font(.caption.monospaced())
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .background(surface2, in: RoundedRectangle(cornerRadius: 10))
        }
        .panelStyle()
    }
}

struct ConditionPresetPanel: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Condition Presets", systemImage: "bolt.badge.clock")

            HStack {
                Picker("Output", selection: $model.activeOutputDevice) {
                    Text("Headphones").tag("Headphones")
                    Text("Built-in Speakers").tag("Built-in Speakers")
                    Text("USB Audio").tag("USB Audio")
                }

                Button {
                    model.simulateOutputDevice(model.activeOutputDevice)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Run")
            }

            HStack {
                Picker("App", selection: $model.lastLaunchedApp) {
                    Text("Safari").tag("Safari")
                    Text("Discord").tag("Discord")
                    Text("Game").tag("Game")
                    Text("Music").tag("Music")
                }

                Button {
                    model.simulateAppLaunch(model.lastLaunchedApp)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Run")
            }

            ForEach($model.conditionRules) { $rule in
                HStack {
                    PillToggle(isOn: $rule.isEnabled)
                    Picker("Trigger", selection: $rule.trigger) {
                        ForEach(ConditionTrigger.allCases) { trigger in
                            Text(trigger.rawValue).tag(trigger)
                        }
                    }
                    TextField("Match", text: $rule.matchValue)
                    Picker("Preset", selection: $rule.preset) {
                        ForEach(RoutePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                }
                .padding(8)
                .background(surface1, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .panelStyle()
    }
}

struct PanelTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
    }
}

struct StudioBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.055, green: 0.06, blue: 0.07),
                Color(red: 0.08, green: 0.09, blue: 0.10),
                Color(red: 0.045, green: 0.05, blue: 0.055)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

extension View {
    func panelStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(glassBorder))
    }
}
