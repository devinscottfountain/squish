import Foundation

/// A preset the user saved from their own settings.
struct SavedPreset: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: EncodeSettings

    var selectionID: String { "custom-\(id.uuidString)" }
}

extension SavedPreset: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, settings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Settings are stored as raw JSON so presets saved before a new option existed still load.
        let raw = try c.decode(Data.self, forKey: .settings)
        settings = EncodeSettings.decodeLenient(raw) ?? EncodeSettings()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(try JSONEncoder().encode(settings), forKey: .settings)
    }
}

extension EncodeSettings {
    /// Copies where-files-go settings from another set, so presets don't move your output folder.
    mutating func adoptOutput(from other: EncodeSettings) {
        outputLocation = other.outputLocation
        outputFolderPath = other.outputFolderPath
        filenameSuffix = other.filenameSuffix
        overwrite = other.overwrite
        threads = other.threads
    }

    /// One-line readout, like "MP4 · H.264 · CRF 23 · AAC 160k".
    var summaryText: String {
        var parts = [container.label]
        if !container.isAnimatedImage && !container.isAudioOnly {
            var codec = videoCodec.label
            if videoCodec == .prores { codec += " \(proresProfile.label)" }
            if hardwareEncoding { codec += " (HW)" }
            parts.append(codec)
            if videoCodec != .prores && videoCodec != .copy {
                switch rateControl {
                case .quality:
                    if let q = CommandBuilder.qualityParameter(for: self) {
                        parts.append(q.flag == "-crf" ? "CRF \(q.value)" : "Q \(q.value)")
                    }
                case .bitrate, .constant: parts.append("\(videoBitrateKbps) kbps")
                case .targetSize: parts.append("≤ \(num(targetSizeMB)) MB")
                }
            }
        }
        if resolution != .original && !container.isAudioOnly { parts.append(resolution.label) }
        if let fps = targetFrameRate, !container.isAudioOnly { parts.append("\(num(fps)) fps") }
        if playbackSpeed != 1 { parts.append("\(num(playbackSpeed))×") }
        if !container.isAnimatedImage {
            if audioCodec == .none {
                parts.append("no audio")
            } else if audioCodec.isLossy {
                parts.append("\(audioCodec.label) \(audioBitrateKbps)k")
            } else {
                parts.append(audioCodec.label)
            }
        }
        return parts.joined(separator: " · ")
    }
}
