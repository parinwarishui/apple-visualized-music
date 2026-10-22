//
//  PlaybackClock.swift
//  Music's playhead between readings. Music only reports its position when asked,
//  so the app keeps the last reading and counts forward from it while playing.
//  While Music is loading or buffering a song it still says "playing" but its
//  position stands still; two readings that barely move mark the clock stalled,
//  and it holds still until Music moves again, instead of running ahead and
//  snapping back. Pure value code, unit-tested.
//

import Foundation

struct PlaybackClock: Equatable {
    /// Seconds. 0 when unknown, e.g. a radio stream.
    var duration = 0.0
    private(set) var isPlaying = false
    /// Music says it's playing, but its position isn't moving (see above).
    private(set) var isStalled = false
    private var anchorPosition = 0.0
    private var anchorTime = 0.0
    /// The last reading taken while playing, to tell moving from stalled.
    private var lastPosition: Double?
    private var lastTime = 0.0

    /// Readings closer together than this don't judge a stall: too little time
    /// to tell a slow playhead from a stopped one.
    static let minimumGap = 0.3
    /// Moving less than this share of the time between readings counts as stalled.
    static let stallRate = 0.5

    /// A fresh reading from Music. `now` is a monotonic clock in seconds.
    mutating func sync(position: Double, playing: Bool, at now: Double) {
        if !playing {
            isStalled = false
            lastPosition = nil
        } else if let last = lastPosition {
            let elapsed = now - lastTime
            if elapsed >= Self.minimumGap {
                let moved = position - last
                // Moving backwards or far forwards is a seek, not a stall.
                isStalled = moved > -0.25 && moved < Self.stallRate * elapsed
                lastPosition = position
                lastTime = now
            }
        } else {
            lastPosition = position
            lastTime = now
        }
        anchor(position, playing: playing, at: now)
    }

    /// Play/pause without a position reading: freeze or resume from where it is.
    /// The next readings judge stalls afresh, so time spent paused isn't mistaken
    /// for a stall.
    mutating func setPlaying(_ playing: Bool, at now: Double) {
        jump(to: position(at: now), playing: playing, at: now)
    }

    /// A position set from here (a seek, a new song) rather than read from Music.
    mutating func jump(to position: Double, playing: Bool, at now: Double) {
        isStalled = false
        lastPosition = nil
        anchor(position, playing: playing, at: now)
    }

    private mutating func anchor(_ position: Double, playing: Bool, at now: Double) {
        anchorPosition = position
        anchorTime = now
        isPlaying = playing
    }

    func position(at now: Double) -> Double {
        let position = anchorPosition + (isPlaying && !isStalled ? now - anchorTime : 0)
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
