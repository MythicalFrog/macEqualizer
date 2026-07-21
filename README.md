# macEqualizer

A native SwiftUI macOS equalizer prototype built as a lightweight Swift Package.

## Current Features

- Fully parametric EQ nodes with frequency, gain, Q, filter shape, enable state, and live biquad coefficient readouts
- Dual-mono editing for independent left and right channel curves
- Vertical frequency controls for every editable EQ node
- Windowed FFT spectrum analyzer behind the EQ curve plot
- Accelerate/vDSP-backed analyzer math on a dedicated high-priority queue
- Dynamic EQ behavior driven by a simulated live input level
- Application routing matrix with per-app volume, preset, plugin, and effect assignments
- Plugin host pipeline model with ordered slots, wet mix, latency, enable state, and serialized state
- AutoEQ profile application plus CSV parsing for custom correction curves
- Condition-based presets triggered by simulated output device changes or app launches
- Experimental Core Audio system tap using `CATapDescription`, a private aggregate device, realtime biquad processing, and AVAudioEngine playback

## Build

This project does not require the full Xcode app. Install Apple's Command Line Tools, then run:

```sh
swift build
```

## Run

```sh
swift run
```

For smoother UI performance, run the optimized build:

```sh
swift run -c release
```

## Live System Audio

The System Audio panel can start an experimental live path on macOS 14.2 or newer:

1. Create a private Core Audio process tap.
2. Exclude the app's own process from the tap to reduce feedback.
3. Wrap the tap in a private aggregate device.
4. Read tapped buffers in a Core Audio IO callback.
5. Process the buffers through the current left/right EQ bands.
6. Play the processed stream through AVAudioEngine.

This is the first real "affects Mac audio" layer. A polished production equalizer still needs hardened routing behavior, packaged permissions/signing, robust device switching, and likely an AudioServerPlugIn or DriverKit-based virtual device for persistent system-wide routing.

## Performance Direction

The UI stays in SwiftUI, while the hot analyzer path uses Apple's Accelerate framework and skips overlapping analyzer frames instead of letting work queue up behind user input. The experimental live audio path uses Core Audio callbacks, preallocated ring buffers, and sample-by-sample biquad processing.
