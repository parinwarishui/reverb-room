//
//  PlaybackClock.swift
//  Music's playhead between readings. Music only reports its position when asked,
//  so the app keeps the last reading and counts forward from it while playing.
//  Pure value code, unit-tested.
//

import Foundation

struct PlaybackClock: Equatable {
    /// Seconds. 0 when unknown, e.g. a radio stream.
    var duration = 0.0
    private(set) var isPlaying = false
    private var anchorPosition = 0.0
    private var anchorTime = 0.0

    /// A fresh reading from Music. `now` is a monotonic clock in seconds.
    mutating func sync(position: Double, playing: Bool, at now: Double) {
        anchorPosition = position
        anchorTime = now
        isPlaying = playing
    }

    /// Play/pause without a position reading: freeze or resume from where it is.
    mutating func setPlaying(_ playing: Bool, at now: Double) {
        sync(position: position(at: now), playing: playing, at: now)
    }

    func position(at now: Double) -> Double {
        let position = anchorPosition + (isPlaying ? now - anchorTime : 0)
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }

    /// "3:07", or "1:02:03" past an hour.
    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Music's `song repeat` setting.
enum RepeatMode: String {
    case off, one, all

    /// Same order as Music's own repeat button: off → all → one → off.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}
