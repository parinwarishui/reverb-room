//
//  Settings.swift
//  What the sliders control, and the six rooms.
//

import Foundation
import ReverbDSP

struct ReverbSettings: Codable, Equatable {
    /// 0...1
    var amount: Double
    /// Seconds for the reverb to die away (RT60), 0.3...10.
    var size: Double
    /// Milliseconds, 0...150.
    var preDelay: Double
    /// 0 = dark, 1 = bright.
    var tone: Double
    /// Semitones, -12...12.
    var pitch: Double
    var nextRoom: Bool

    static let amountRange = 0.0...1.0
    static let sizeRange = 0.3...10.0
    static let preDelayRange = 0.0...150.0
    static let toneRange = 0.0...1.0
    static let pitchRange = -12.0...12.0

    var shape: ReverbShape {
        ReverbShape(decay: size, preDelay: preDelay / 1000, tone: tone)
    }

    /// Equal at the precision the sliders show.
    func matches(_ other: ReverbSettings) -> Bool {
        abs(amount - other.amount) < 0.005 && abs(size - other.size) < 0.05
            && abs(preDelay - other.preDelay) < 0.5 && abs(tone - other.tone) < 0.005
            && abs(pitch - other.pitch) < 0.05 && nextRoom == other.nextRoom
    }

    var toneName: String {
        switch tone {
        case ..<0.2: return "Dark"
        case ..<0.4: return "Mellow"
        case ..<0.65: return "Warm"
        case ..<0.85: return "Clear"
        default: return "Bright"
        }
    }

    // MARK: Persistence

    private static let key = "settings"

    static func load() -> ReverbSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var saved = try? JSONDecoder().decode(ReverbSettings.self, from: data) else {
            return Preset.slowedReverb.settings
        }
        saved.amount = saved.amount.clamped(to: amountRange)
        saved.size = saved.size.clamped(to: sizeRange)
        saved.preDelay = saved.preDelay.clamped(to: preDelayRange)
        saved.tone = saved.tone.clamped(to: toneRange)
        saved.pitch = saved.pitch.clamped(to: pitchRange)
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case slowedReverb, concertHall, cathedral, studioRoom, nextRoom, vaporwave

    var id: String { rawValue }

    var name: String {
        switch self {
        case .slowedReverb: return "Slowed + Reverb"
        case .concertHall: return "Concert Hall"
        case .cathedral: return "Cathedral"
        case .studioRoom: return "Studio Room"
        case .nextRoom: return "Next Room"
        case .vaporwave: return "Vaporwave"
        }
    }

    var settings: ReverbSettings {
        switch self {
        case .slowedReverb:
            return ReverbSettings(amount: 0.45, size: 4.2, preDelay: 30, tone: 0.55, pitch: -2.8, nextRoom: false)
        case .concertHall:
            return ReverbSettings(amount: 0.35, size: 2.6, preDelay: 25, tone: 0.6, pitch: 0, nextRoom: false)
        case .cathedral:
            return ReverbSettings(amount: 0.55, size: 7.5, preDelay: 60, tone: 0.45, pitch: 0, nextRoom: false)
        case .studioRoom:
            return ReverbSettings(amount: 0.22, size: 0.6, preDelay: 8, tone: 0.7, pitch: 0, nextRoom: false)
        case .nextRoom:
            return ReverbSettings(amount: 0.4, size: 1.4, preDelay: 12, tone: 0.4, pitch: 0, nextRoom: true)
        case .vaporwave:
            return ReverbSettings(amount: 0.55, size: 6.0, preDelay: 45, tone: 0.35, pitch: -5, nextRoom: false)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
