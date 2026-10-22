//
//  Freeverb.swift
//
//  AVM Freeverb branch only. A from-scratch Swift port of Jezar at
//  Dreampoint's Freeverb algorithm (the classic Schroeder/Moorer-derived
//  design: a bank of lowpass-damped comb filters in parallel, feeding a
//  short series of allpass filters, per channel), run in-process inside
//  Renderer.process rather than as an Audio Unit in the AVAudioEngine graph.
//
//  Why not a graph node: inserting a genuinely custom DSP stage into
//  AVAudioEngine as a connectable node means writing a full AUAudioUnit
//  subclass (bus arrays, allocateRenderResources, a parameter tree, the
//  render block protocol) -- real boilerplate, easy to get subtly wrong
//  without a working build here to check it against. Processing the
//  engine's already-rendered output in Renderer.process instead is far
//  simpler and everything this app does post-render (the hard clip) already
//  works the same way. The cost: reverb now runs after the limiter instead
//  of before it (the chain was EQ -> filter -> reverb -> limiter -> clip;
//  it's now EQ -> filter -> limiter -> reverb -> clip), so the limiter no
//  longer catches peaks the reverb itself adds. Freeverb's own topology
//  keeps that bounded on its own -- the comb feedback coefficient this file
//  uses never reaches 1.0 (see scaleRoom/offsetRoom below), so it can't
//  build up without limit the way a true unstable feedback loop could --
//  and the hard clip after it is still there as a safety net either way.
//
//  Not yet confirmed by ear: the preset room size/damping/width numbers in
//  FreeverbPreset, and the 120 ms "listen for distortion" story above.
//

import Foundation
import os

/// A few floats, updated rarely (the user moving a slider) and read on every
/// render cycle. AVMAtomics (the C target used by Meter) exposes a fixed API
/// for peak/RMS specifically, not generic atomics, so extending it for this
/// would mean new C code with no build here to check it against. A spinlock
/// around a plain struct copy is the standard, well-understood alternative
/// for infrequent parameter updates in real-time audio code; unlike Meter
/// (written every cycle, read at 20-30 Hz by the UI, where lock-free atomics
/// earn their keep), this is written a few times a second at most and the
/// critical section is a handful of Float copies, so a brief lock is in no
/// danger of holding up the render thread long enough to be heard.
private final class UnfairLock {
    private var primitive = os_unfair_lock()
    func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&primitive)
        defer { os_unfair_lock_unlock(&primitive) }
        return body()
    }
}

/// AVM's five "Space" choices, now driving Freeverb's room size, damping and
/// width directly instead of an AVAudioUnitReverbPreset or a hosted plugin's
/// Mode. A first pass by ear-of-description, not measured -- see the file
/// header and Decisions.md.
enum FreeverbPreset: String, CaseIterable {
    case room = "Room"
    case chamber = "Chamber"
    case plate = "Plate"
    case hall = "Hall"
    case cathedral = "Cathedral"

    /// 0...1. Scaled internally to Freeverb's feedback coefficient.
    var roomSize: Float {
        switch self {
        case .room: return 0.3
        case .chamber: return 0.45
        case .plate: return 0.55
        case .hall: return 0.7
        case .cathedral: return 0.9
        }
    }

    /// 0...1. Higher = darker, faster-decaying highs.
    var damping: Float {
        switch self {
        case .room: return 0.5
        case .chamber: return 0.45
        case .plate: return 0.25   // plates read as bright/dense: keep highs alive
        case .hall: return 0.4
        case .cathedral: return 0.35
        }
    }

    /// 0...1. Stereo spread; 0 collapses toward mono-ish, 1 is widest.
    var width: Float {
        switch self {
        case .room: return 0.7
        case .chamber: return 0.8
        case .plate: return 0.6
        case .hall: return 1.0
        case .cathedral: return 1.0
        }
    }
}

/// A single feedback comb filter with a one-pole lowpass inside the feedback
/// path (the "damping" control) -- the building block Freeverb uses eight of,
/// per channel, in parallel.
private final class CombFilter {
    private var buffer: [Float]
    private var index = 0
    private var filterStore: Float = 0

    init(delaySamples: Int) {
        buffer = [Float](repeating: 0, count: max(delaySamples, 1))
    }

    @inline(__always)
    func process(_ input: Float, feedback: Float, damp1: Float, damp2: Float) -> Float {
        let output = buffer[index]
        filterStore = output * damp2 + filterStore * damp1
        buffer[index] = input + filterStore * feedback
        index += 1
        if index >= buffer.count { index = 0 }
        return output
    }
}

/// A single allpass filter -- flat frequency response, diffuses the comb
/// filters' output without colouring it further. Freeverb chains four of
/// these in series, per channel, after the combs.
private final class AllpassFilter {
    private var buffer: [Float]
    private var index = 0
    private let feedback: Float = 0.5

    init(delaySamples: Int) {
        buffer = [Float](repeating: 0, count: max(delaySamples, 1))
    }

    @inline(__always)
    func process(_ input: Float) -> Float {
        let bufferedValue = buffer[index]
        let output = -input + bufferedValue
        buffer[index] = input + bufferedValue * feedback
        index += 1
        if index >= buffer.count { index = 0 }
        return output
    }
}

/// The reverb itself: 8 combs + 4 allpasses per channel, run in place on
/// Renderer's already-rendered output buffers. One instance per TapPipeline,
/// sized to the real sample rate at construction (the classic delay lengths
/// below are Jezar's reference lengths at 44.1 kHz, scaled proportionally).
final class Freeverb {
    // Jezar's reference comb/allpass lengths, samples at 44.1 kHz, and the
    // stereo offset applied to the right channel's copies.
    private static let combTuningL: [Int] = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116]
    private static let allpassTuningL: [Int] = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let referenceSampleRate = 44_100.0

    // Also Jezar's constants: fixedGain keeps the combs' input small enough
    // that the feedback network never runs hot; scaleRoom/offsetRoom map the
    // 0...1 roomSize control to a feedback coefficient that tops out at 0.98,
    // short of the 1.0 that would make the combs an unstable, runaway loop.
    private static let fixedGain: Float = 0.015
    private static let scaleRoom: Float = 0.28
    private static let offsetRoom: Float = 0.7
    private static let scaleDamp: Float = 0.4

    struct Parameters {
        var roomSize: Float = FreeverbPreset.hall.roomSize
        var damping: Float = FreeverbPreset.hall.damping
        var width: Float = FreeverbPreset.hall.width
        var wetDryMix: Float = 35   // 0...100, same units as AVM's existing Mix slider
        var bypassed: Bool = false
    }

    private let combsL: [CombFilter]
    private let combsR: [CombFilter]
    private let allpassesL: [AllpassFilter]
    private let allpassesR: [AllpassFilter]
    private let lock = UnfairLock()
    private var parameters = Parameters()

    init(sampleRate: Double) {
        let scale = sampleRate > 0 ? sampleRate / Self.referenceSampleRate : 1
        combsL = Self.combTuningL.map { CombFilter(delaySamples: Int((Double($0) * scale).rounded())) }
        combsR = Self.combTuningL.map {
            CombFilter(delaySamples: Int((Double($0 + Self.stereoSpread) * scale).rounded()))
        }
        allpassesL = Self.allpassTuningL.map { AllpassFilter(delaySamples: Int((Double($0) * scale).rounded())) }
        allpassesR = Self.allpassTuningL.map {
            AllpassFilter(delaySamples: Int((Double($0 + Self.stereoSpread) * scale).rounded()))
        }
    }

    /// Called from the work queue (TapPipeline's setters). Thread-safety is
    /// the lock, not which queue calls this.
    func setParameters(_ new: Parameters) {
        lock.locked { parameters = new }
    }

    func apply(_ preset: FreeverbPreset) {
        lock.locked {
            parameters.roomSize = preset.roomSize
            parameters.damping = preset.damping
            parameters.width = preset.width
        }
    }

    func setWetDryMix(_ value: Float) {
        lock.locked { parameters.wetDryMix = value }
    }

    func setBypassed(_ bypassed: Bool) {
        lock.locked { parameters.bypassed = bypassed }
    }

    /// Real-time: called from the IOProc, in place on Renderer's own output
    /// buffers. No allocation; the only non-trivial cost is the brief lock
    /// above to snapshot the current parameters once per call (not per
    /// sample), and the per-sample work below is a fixed, small number of
    /// comb/allpass taps -- no system calls, no Objective-C.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let p = lock.locked { parameters }
        guard !p.bypassed else { return }

        let feedback = p.roomSize * Self.scaleRoom + Self.offsetRoom
        let damp1 = p.damping * Self.scaleDamp
        let damp2 = 1 - damp1
        let wet = min(max(p.wetDryMix / 100, 0), 1)
        let dry = 1 - wet
        let wet1 = wet * (p.width / 2 + 0.5)
        let wet2 = wet * ((1 - p.width) / 2)

        for i in 0..<frameCount {
            let dryL = left[i]
            let dryR = right[i]
            let input = (dryL + dryR) * Self.fixedGain

            var wetL: Float = 0
            var wetR: Float = 0
            for comb in combsL { wetL += comb.process(input, feedback: feedback, damp1: damp1, damp2: damp2) }
            for comb in combsR { wetR += comb.process(input, feedback: feedback, damp1: damp1, damp2: damp2) }
            for allpass in allpassesL { wetL = allpass.process(wetL) }
            for allpass in allpassesR { wetR = allpass.process(wetR) }

            left[i] = wetL * wet1 + wetR * wet2 + dryL * dry
            right[i] = wetR * wet1 + wetL * wet2 + dryR * dry
        }
    }
}
