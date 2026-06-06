# Media Accessibility

Covers Captions, Audio Descriptions, Speech synthesis, Chart accessibility, and audio session considerations — required for two App Store Accessibility Nutrition Labels.

## Contents
- [Captions and Subtitles](#captions-and-subtitles)
- [Audio Descriptions](#audio-descriptions)
- [Speech Synthesis](#speech-synthesis)
- [Chart Accessibility](#chart-accessibility)
- [Common Failures](#common-failures)

---

## Captions and Subtitles

### Nutrition Label Criteria

To declare **Captions** support:
- Captions are enabled by default when the system caption setting is on
- All first-party video dialogue and relevant sounds are captioned
- SDH (Subtitles for Deaf/Hard of Hearing) preferred over plain subtitles
- Third-party content shows a CC or SDH badge indicator
- Audio-only content has text transcripts available

### AVPlayerViewController — Built-in Support (Automatic)

`AVPlayerViewController` handles caption selection, appearance, and the system toggle automatically. When the user has "Closed Captions + SDH" enabled in Settings, captions activate without any code.

```swift
// ✅ Built-in AVPlayerViewController — captions work automatically
import AVKit

let player = AVPlayer(url: videoURL)
let playerVC = AVPlayerViewController()
playerVC.player = player
present(playerVC, animated: true) {
    player.play()
}
```

```swift
// SwiftUI equivalent
VideoPlayer(player: AVPlayer(url: videoURL))
    .frame(height: 300)
```

### Checking the System Caption Setting

```swift
import MediaAccessibility

// Check if the user has closed captions enabled
let captionType = MACaptionAppearanceGetDisplayType(.user)
switch captionType {
case .alwaysOn:
    // Captions always shown
    break
case .automatic:
    // System decides based on content and audio route
    break
case .forcedOnly:
    // Only forced subtitles
    break
@unknown default:
    break
}
```

### Serving Caption Tracks

Caption tracks must be embedded in your media asset or served via HLS with `.vtt` or `.srt` subtitle tracks.

```swift
// Programmatically select caption track
let asset = AVAsset(url: videoURL)

Task {
    let characteristics = try await asset.loadMediaSelectionGroup(for: .legible)
    if let group = characteristics {
        // Find SDH (Subtitles for Deaf/Hard of Hearing) track
        let sdhOption = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options,
            withMediaCharacteristics: [.describesVideoForAccessibility, .isSDH]
        ).first

        // Find any caption track
        let captionOption = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options,
            withMediaCharacteristics: [.legible]
        ).first

        // Activate the preferred option
        await player.currentItem?.select(sdhOption ?? captionOption, in: group)
    }
}
```

### Caption Appearance Customization

```swift
// Caption styling follows system preferences by default
// Override only for branded players that need custom styling

// Check user-preferred caption style
let foregroundColor = MACaptionAppearanceCopyForegroundColor(.user, nil)
let fontSize = MACaptionAppearanceGetRelativeCharacterSize(.user)
let fontStyle = MACaptionAppearanceGetTextEdgeStyle(.user)
```

### SDH vs Regular Subtitles

| Type | Content | When to Use |
|---|---|---|
| SDH (Subtitles for Deaf/Hard of Hearing) | Dialogue + sound effects + speaker identification | Preferred for accessibility |
| Subtitles | Dialogue only (translation) | Foreign language content |
| Forced Subtitles | Untranslated speech only | When characters speak a foreign language mid-content |
| Closed Captions (CC) | Dialogue + sound effects | Legacy format, same role as SDH |

Mark SDH tracks with `AVMediaCharacteristic.isSDH` when creating custom tracks.

---

## Audio Descriptions

### Nutrition Label Criteria

To declare **Audio Descriptions** support:
- Audio Descriptions are enabled by default when the system AD setting is on
- All first-party video visual content is narrated (actions, scene changes, on-screen text)
- Game interstitials and cut scenes are covered
- Third-party content shows an "AD" badge indicator
- Don't claim support if very little described content exists

### AVPlayerViewController — Built-in Support

`AVPlayerViewController` automatically selects an Audio Description track when the user has "Audio Descriptions" enabled in Settings.

```swift
// Built-in: no code required when using AVPlayerViewController
// AD tracks must be included in the media asset or HLS manifest
```

### Checking for Audio Description Track

```swift
let asset = AVAsset(url: videoURL)

Task {
    let group = try? await asset.loadMediaSelectionGroup(for: .audible)
    if let group {
        let adOptions = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options,
            withMediaCharacteristics: [.describesVideoForAccessibility]
        )
        let hasAudioDescription = !adOptions.isEmpty
        // Show "AD" badge in UI if hasAudioDescription
    }
}
```

### Respecting Spoken Audio Sessions

When your app plays audio that competes with VoiceOver or Audio Descriptions, use the `.spokenAudio` mode to duck or pause:

```swift
import AVFoundation

// Configure audio session to respect spoken audio (VoiceOver, Audio Descriptions)
try? AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .spokenAudio,
    options: [.duckOthers]  // duck, don't interrupt
)

// For apps where spoken word IS the primary content (audiobooks, podcasts)
try? AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .spokenAudio
    // No .duckOthers — this IS the audio that should not be ducked
)
```

### Detecting the System Audio Description Setting

```swift
// No direct API equivalent to MACaptionAppearance for Audio Descriptions
// AVPlayerViewController handles it automatically
// For custom players, observe AVAudioSession for changes
NotificationCenter.default.addObserver(
    forName: AVAudioSession.routeChangeNotification,
    object: nil,
    queue: .main
) { _ in
    // Re-evaluate AD track selection after route change
}
```

---

## Speech Synthesis

For apps that generate spoken content (reading apps, navigation, notifications).

### Basic AVSpeechSynthesizer

```swift
import AVFoundation

let synthesizer = AVSpeechSynthesizer()

func speak(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.pitchMultiplier = 1.0   // 0.5 (low) to 2.0 (high)
    utterance.volume = 1.0
    utterance.preUtteranceDelay = 0.1

    synthesizer.speak(utterance)
}

// Pause and resume
synthesizer.pauseSpeaking(at: .word)
synthesizer.continueSpeaking()

// Stop
synthesizer.stopSpeaking(at: .immediate)  // or .word, .sentence
```

### SSML-Based Utterance (iOS 16+)

```swift
// Use SSML for fine-grained prosody control
let ssml = """
<speak>
    <s>Welcome to <emphasis level="strong">My App</emphasis>.</s>
    <break time="500ms"/>
    <s>Your balance is <say-as interpret-as="currency" language="en-US">$1,234.56</say-as>.</s>
</speak>
"""

if let utterance = AVSpeechUtterance(ssmlRepresentation: ssml) {
    synthesizer.speak(utterance)
}
```

### Personal Voice (iOS 17+)

```swift
import AVFoundation

// Request access to Personal Voice
AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
    if status == .authorized {
        // List available personal voices
        let personalVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.voiceTraits.contains(.isPersonalVoice) }

        if let voice = personalVoices.first {
            let utterance = AVSpeechUtterance(string: "Hello!")
            utterance.voice = voice
            synthesizer.speak(utterance)
        }
    }
}
```

### AVSpeechSynthesizerDelegate

```swift
class NarratorController: NSObject, AVSpeechSynthesizerDelegate {
    let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didStart utterance: AVSpeechUtterance) {
        // Update UI — speaking started
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        // Proceed to next utterance or update UI
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        // Highlight the currently spoken word
    }
}
```

### Audio Session for Speech Apps

```swift
// Configure session for spoken word apps (audiobooks, narration)
try? AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .spokenAudio,
    options: [.allowBluetooth, .allowAirPlay]
)
try? AVAudioSession.sharedInstance().setActive(true)
```

---

## Chart Accessibility

Charts are visual; users who cannot see them need structured data alternatives.

### SwiftUI Charts: `.accessibilityChartDescriptor(_:)`

```swift
import Charts

struct SalesChartDescriptor: AXChartDescriptorRepresentable {
    let data: [SalesData]

    func makeChartDescriptor() -> AXChartDescriptor {
        let months = data.map(\.month)
        let maxSales = data.map(\.sales).max() ?? 0

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Month",
            categoryOrder: months
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Revenue (USD)",
            range: 0...Double(maxSales),
            gridlinePositions: []
        ) { value in
            "$\(Int(value).formatted())"  // format for speech
        }

        let series = AXDataSeriesDescriptor(
            name: "Monthly Sales",
            isContinuous: false,
            dataPoints: data.map { item in
                AXDataPoint(x: item.month, y: Double(item.sales))
            }
        )

        return AXChartDescriptor(
            title: "Monthly Sales Report",
            summary: "Sales increased 23% year-over-year, peaking in December.",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

// Apply to the chart
Chart(salesData) { item in
    BarMark(
        x: .value("Month", item.month),
        y: .value("Sales", item.sales)
    )
}
.accessibilityChartDescriptor(SalesChartDescriptor(data: salesData))
```

### Multi-Series Charts

```swift
let descriptor = AXChartDescriptor(
    title: "Revenue by Region",
    summary: "North America leads, followed by Europe and Asia.",
    xAxis: AXCategoricalDataAxisDescriptor(title: "Quarter", categoryOrder: ["Q1", "Q2", "Q3", "Q4"]),
    yAxis: AXNumericDataAxisDescriptor(title: "Revenue (M)", range: 0...500, gridlinePositions: []) { "\($0)M" },
    additionalAxes: [],
    series: [
        AXDataSeriesDescriptor(name: "North America", isContinuous: true,
            dataPoints: naData.map { AXDataPoint(x: $0.quarter, y: $0.revenue) }),
        AXDataSeriesDescriptor(name: "Europe", isContinuous: true,
            dataPoints: euData.map { AXDataPoint(x: $0.quarter, y: $0.revenue) })
    ]
)
```

### Text Alternatives for Custom Charts

For non-Swift Charts visualizations (Core Graphics, custom drawing):

```swift
// Provide a data table as an accessibility alternative
CustomBarChartView(data: chartData)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Sales chart")
    .accessibilityValue(chartData.map { "\($0.label): \($0.value)" }.joined(separator: ", "))

// Or use accessibilityCustomContent for detailed chunked delivery
CustomBarChartView(data: chartData)
    .accessibilityLabel("Quarterly Revenue Chart")
    .accessibilityCustomContent("Summary", "Revenue grew 15% this year", importance: .high)
    .accessibilityCustomContent(
        "Data",
        chartData.map { "\($0.quarter): \($0.value)" }.joined(separator: "; ")
    )
```

---

## Common Failures

| Failure | Category | Fix |
|---|---|---|
| Captions don't enable automatically | Captions | Use `AVPlayerViewController`; check system caption setting via `MACaptionAppearanceGetDisplayType` |
| No caption tracks in video | Captions | Embed `.vtt`/`.srt` tracks or include SDH in HLS manifest |
| Audio Descriptions never activate | Audio Descriptions | Use `AVPlayerViewController`; embed AD audio tracks with `.describesVideoForAccessibility` characteristic |
| App audio ducks VoiceOver | Audio Session | Set `.spokenAudio` mode with `.duckOthers` option |
| Chart data inaccessible to VoiceOver | Charts | Add `.accessibilityChartDescriptor(_:)` with meaningful summary |
| Speech synthesizer interrupts VoiceOver | Speech | Check `UIAccessibility.isVoiceOverRunning` and pause/queue synthesis |
| Custom media player ignores caption setting | Captions | Query `MACaptionAppearanceGetDisplayType` and auto-select caption track |
| No transcript for audio-only content | Captions | Provide static text transcript alongside audio |
