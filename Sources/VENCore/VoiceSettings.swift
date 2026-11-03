import Foundation
import VENDSP

/// Every knob of the voice chain, in a form that can be saved and edited from SwiftUI.
/// Decodes `data`, keeping `defaults` for anything an older version didn't save.
public func decodeKeepingDefaults<T: Codable>(_ data: Data, defaults: T) -> T? {
    guard let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any],
          let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { _, new in new })
    else { return nil }
    return try? JSONDecoder().decode(T.self, from: merged)
}

public struct VoiceSettings: Codable, Equatable {
    public enum HumMode: String, Codable, CaseIterable, Identifiable {
        case off, auto, hz50, hz60
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .off: return "Off"
            case .auto: return "Auto-detect"
            case .hz50: return "50 Hz"
            case .hz60: return "60 Hz"
            }
        }
    }

    public var bypass = false
    public var mute = false

    public var highPassEnabled = true
    public var highPassHz: Float = 80

    public var humMode: HumMode = .auto
    public var humHarmonics = 8

    public var noiseReductionEnabled = true
    public var noiseReductionStrength: Float = 0.85
    /// DeepFilterNet ("Studio") instead of RNNoise, when it's installed. Off by default: it adds delay and CPU.
    public var studioNoise = false

    public var voiceEQEnabled = true
    public var voiceEQAmount: Float = 0.5

    public var deEsserEnabled = true
    public var deEsserAmount: Float = 0.5

    public var levelerEnabled = true
    public var levelerTargetDB: Float = -20
    public var levelerMaxGainDB: Float = 15

    public var compressorEnabled = true
    public var compressorAmount: Float = 0.4

    public var pauseGateEnabled = false
    public var pauseGateDepthDB: Float = 10

    public var limiterEnabled = true
    public var limiterCeilingDB: Float = -1

    public var outputGainDB: Float = 0

    public init() {}

    public var params: ven_params {
        var p = ven_params()
        ven_params_default(&p)
        p.bypass = bypass ? 1 : 0
        p.mute = mute ? 1 : 0
        p.hpf_enabled = highPassEnabled ? 1 : 0
        p.hpf_hz = highPassHz
        switch humMode {
        case .off: p.hum_mode = Int32(VEN_HUM_OFF.rawValue)
        case .auto: p.hum_mode = Int32(VEN_HUM_AUTO.rawValue)
        case .hz50: p.hum_mode = Int32(VEN_HUM_50.rawValue)
        case .hz60: p.hum_mode = Int32(VEN_HUM_60.rawValue)
        }
        p.hum_harmonics = Int32(humHarmonics)
        p.nr_enabled = noiseReductionEnabled ? 1 : 0
        p.nr_strength = noiseReductionStrength
        p.eq_enabled = voiceEQEnabled ? 1 : 0
        p.eq_amount = voiceEQAmount
        p.deess_enabled = deEsserEnabled ? 1 : 0
        p.deess_amount = deEsserAmount
        p.leveler_enabled = levelerEnabled ? 1 : 0
        p.leveler_target_db = levelerTargetDB
        p.leveler_max_gain_db = levelerMaxGainDB
        p.comp_enabled = compressorEnabled ? 1 : 0
        p.comp_amount = compressorAmount
        p.gate_enabled = pauseGateEnabled ? 1 : 0
        p.gate_depth_db = pauseGateDepthDB
        p.limiter_enabled = limiterEnabled ? 1 : 0
        p.limiter_ceiling_db = limiterCeilingDB
        p.output_gain_db = outputGainDB
        return p
    }
}

public struct VoicePreset: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let settings: VoiceSettings

    public static let all: [VoicePreset] = [podcast, meeting, streaming, voiceOver, gentle]

    public static let podcast = VoicePreset(id: "podcast", name: "Podcast", summary: "Strong cleanup, steady level", settings: VoiceSettings())

    public static let meeting: VoicePreset = {
        var s = VoiceSettings()
        s.noiseReductionStrength = 1
        s.voiceEQAmount = 0.3
        s.compressorAmount = 0.3
        s.pauseGateEnabled = true
        s.pauseGateDepthDB = 12
        return VoicePreset(id: "meeting", name: "Meeting", summary: "Maximum noise removal, quiet pauses", settings: s)
    }()

    public static let streaming: VoicePreset = {
        var s = VoiceSettings()
        s.compressorAmount = 0.6
        s.levelerTargetDB = -18
        s.voiceEQAmount = 0.7
        return VoicePreset(id: "streaming", name: "Streaming", summary: "Punchy and forward", settings: s)
    }()

    public static let voiceOver: VoicePreset = {
        var s = VoiceSettings()
        s.noiseReductionStrength = 0.7
        s.voiceEQAmount = 0.6
        s.compressorAmount = 0.5
        s.pauseGateEnabled = true
        s.pauseGateDepthDB = 8
        return VoicePreset(id: "voiceover", name: "Voice-over", summary: "Polished, natural noise floor", settings: s)
    }()

    public static let gentle: VoicePreset = {
        var s = VoiceSettings()
        s.noiseReductionStrength = 0.5
        s.voiceEQEnabled = false
        s.deEsserAmount = 0.3
        s.compressorAmount = 0.2
        return VoicePreset(id: "gentle", name: "Gentle", summary: "Light touch, keeps room sound", settings: s)
    }()
}
