//
//  SupermassiveReverb.swift
//
//  SuperMassive branch only. Optional swap-in for the stock AVAudioUnitReverb
//  (AUReverb2): if Valhalla Supermassive (free, valhalladsp.com) is installed
//  as a system Audio Unit, AVM loads it instead and drives it through the same
//  five "Space" presets the UI already offers. If it isn't installed, AVM falls
//  back to the stock reverb with no change in behaviour — nothing is bundled
//  or redistributed; the user installs their own copy.
//
//  Valhalla doesn't publish Supermassive's internal parameter IDs or its exact
//  per-parameter ranges, so every control here is found by matching its
//  AUParameterTree display name at runtime (case-insensitive substring), not a
//  hardcoded address, and every numeric value is set as a 0...1 fraction of
//  whatever min...max the live parameter itself reports. That also means this
//  keeps working across a Supermassive update that renumbers parameters, and
//  degrades gracefully (one dlog line, nothing else) if a name ever doesn't
//  match. Parameter names and the eight Mode characters come from Valhalla's
//  own docs, not guesswork:
//    https://valhalladsp.com/?p=427500 (the controls)
//    https://valhalladsp.com/2020/05/07/valhallasupermassive-the-modes/ (the modes)
//
//  NOT YET CONFIRMED BY EAR OR AGAINST THE REAL PLUGIN: the exact display-name
//  strings Supermassive's AUParameterTree actually uses (e.g. "Mix" vs
//  "Dry/Wet", "Mod Rate" vs "Rate") and the preset fractions below, which are a
//  first tuning pass, not a measured one. Run ./build.sh debug and watch for
//  "Supermassive: no parameter matching ..." lines — that names exactly which
//  control didn't match and needs its search string adjusted here.
//

import AVFoundation
import AudioToolbox

/// AVM's five "Space" choices. Replaces AVAudioUnitReverbPreset (an Int-backed
/// Apple enum that only means something to AVAudioUnitReverb) with AVM's own
/// String-backed one, so the same five names can drive either reverb engine.
enum SupermassiveReverbPreset: String, CaseIterable {
    case room = "Room"
    case chamber = "Chamber"
    case plate = "Plate"
    case hall = "Hall"
    case cathedral = "Cathedral"

    /// The AVAudioUnitReverb preset used when Supermassive isn't installed —
    /// same mapping AVM always used, so the fallback sounds exactly as before.
    var stockFallback: AVAudioUnitReverbPreset {
        switch self {
        case .room: return .mediumRoom
        case .chamber: return .mediumChamber
        case .plate: return .plate
        case .hall: return .largeHall
        case .cathedral: return .cathedral
        }
    }

    /// Supermassive's own Mode for this preset (set via the Mode parameter's
    /// valueStrings). Picked from Valhalla's descriptions, not measured by ear.
    var mode: String {
        switch self {
        case .room: return "Gemini"                  // fast onset, natural exponential fade
        case .chamber: return "Hydra"                 // fast onset, rich lingering fade, lush mod
        case .plate: return "Lyra"                    // compact, fast onset, long tail, low density
        case .hall: return "Centaurus"                 // slower onset, sustained body, grows with warp
        case .cathedral: return "Great Annihilator"    // slow onset, pre-delay, very long fade
        }
    }

    /// Fractions of each parameter's own live min...max range (not absolute
    /// values — see the file header). A first pass, meant to be retuned by ear.
    /// Pulled back noticeably (Warp/Feedback/Density especially) after a real
    /// run came back "too intense" even with Mix near 0 — that turned out to
    /// be a separate Mix-scaling bug (see setMix), but Supermassive leans huge
    /// even at moderate settings, so these stay conservative until confirmed
    /// otherwise by ear.
    var fractions: SupermassiveFractions {
        switch self {
        case .room:
            return SupermassiveFractions(width: 0.4, delay: 0.1, warp: 0.15, feedback: 0.2,
                                         density: 0.35, modRate: 0.15, modDepth: 0.06,
                                         eqHighCut: 0.9, eqLowCut: 0.05)
        case .chamber:
            return SupermassiveFractions(width: 0.45, delay: 0.15, warp: 0.2, feedback: 0.25,
                                         density: 0.4, modRate: 0.2, modDepth: 0.08,
                                         eqHighCut: 0.85, eqLowCut: 0.06)
        case .plate:
            return SupermassiveFractions(width: 0.35, delay: 0.12, warp: 0.15, feedback: 0.2,
                                         density: 0.25, modRate: 0.25, modDepth: 0.07,
                                         eqHighCut: 0.92, eqLowCut: 0.03)
        case .hall:
            return SupermassiveFractions(width: 0.55, delay: 0.25, warp: 0.3, feedback: 0.35,
                                         density: 0.45, modRate: 0.18, modDepth: 0.1,
                                         eqHighCut: 0.8, eqLowCut: 0.08)
        case .cathedral:
            return SupermassiveFractions(width: 0.65, delay: 0.35, warp: 0.4, feedback: 0.45,
                                         density: 0.55, modRate: 0.15, modDepth: 0.12,
                                         eqHighCut: 0.65, eqLowCut: 0.15)
        }
    }
}

/// One of Supermassive's own parameters, wrapped just enough for SwiftUI:
/// stable `id` (AUParameter's address, not its display name, which isn't
/// guaranteed unique) and Identifiable/Hashable so it can drive a ForEach.
struct SupermassiveControl: Identifiable, Hashable {
    let id: AUParameterAddress
    let param: AUParameter

    static func == (lhs: SupermassiveControl, rhs: SupermassiveControl) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SupermassiveFractions {
    var width: Float
    var delay: Float
    var warp: Float
    var feedback: Float
    var density: Float
    var modRate: Float
    var modDepth: Float
    var eqHighCut: Float
    var eqLowCut: Float
}

/// Finds and drives one installed copy of Valhalla Supermassive (or anything
/// else literally named "Supermassive" — matched by name, since Valhalla
/// doesn't publish a fixed component subtype to check against).
final class SupermassiveReverb {
    let unit: AVAudioUnit
    private let tree: AUParameterTree?
    private var missingParameterNames: Set<String> = []

    private init(unit: AVAudioUnit) {
        self.unit = unit
        self.tree = unit.auAudioUnit.parameterTree
    }

    /// Searches installed Audio Units and, if found, instantiates one. Blocks
    /// the calling thread briefly (AU instantiation is asynchronous) — only
    /// call this from TapPipeline.start, already on AVM's background work
    /// queue, never from the real-time render thread.
    static func locate() -> SupermassiveReverb? {
        let wildcard = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                  componentSubType: 0, componentManufacturer: 0,
                                                  componentFlags: 0, componentFlagsMask: 0)
        let match = AVAudioUnitComponentManager.shared()
            .components(matching: wildcard)
            .first { $0.name.localizedCaseInsensitiveContains("supermassive") }
        guard let match else {
            dlog("Supermassive not found among installed Audio Units — using the built-in reverb")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var instantiated: AVAudioUnit?
        AVAudioUnit.instantiate(with: match.audioComponentDescription, options: []) { unit, error in
            if let error {
                dlog("Supermassive found (\(match.name)) but failed to load: \(error.localizedDescription)")
            }
            instantiated = unit
            semaphore.signal()
        }
        // Instantiation is normally near-instant; 5 s only guards against a
        // plugin that hangs instead of calling back.
        guard semaphore.wait(timeout: .now() + 5) == .success, let instantiated else {
            dlog("Supermassive: instantiation didn't complete in time — using the built-in reverb")
            return nil
        }
        dlog("Loaded reverb plugin:", private: "\(match.name) by \(match.manufacturerName)")
        let reverb = SupermassiveReverb(unit: instantiated)
        reverb.logDiscoveredInterface()
        return reverb
    }

    /// Prints the plugin's real parameter names and factory preset names once,
    /// on load. Answers two things no amount of guessing from Valhalla's
    /// marketing page can: exactly which display-name strings this copy
    /// exposes (for the "no parameter matching" lines elsewhere in this file),
    /// and what its own curated presets are called -- likely a better source
    /// for a natural-sounding preset than this file's hand-picked fractions.
    private func logDiscoveredInterface() {
        let paramNames = tree?.allParameters.map(\.displayName).joined(separator: ", ") ?? "(no parameter tree)"
        dlog("Supermassive parameters:", private: paramNames)
        let presetNames = unit.auAudioUnit.factoryPresets?.map(\.name).joined(separator: ", ")
        dlog("Supermassive factory presets:", private: presetNames ?? "(none reported)")
    }

    /// AUAudioUnit's own bypass flag, not the classic AudioUnitSetProperty the
    /// stock Apple units use elsewhere in this file: a modern AUv3 plugin isn't
    /// guaranteed to implement the legacy kAudioUnitProperty_BypassEffect, but
    /// shouldBypassEffect is bridged for both legacy (AUv2) and native (AUv3)
    /// units by AVAudioEngine, so it works either way Supermassive ships.
    func setBypass(_ bypass: Bool) {
        unit.auAudioUnit.shouldBypassEffect = bypass
    }

    /// Every parameter Supermassive itself reports, for a UI that doesn't
    /// hardcode which ones exist or what they're called -- used by the "full
    /// control" rack in Views.swift. AUParameter.value is safe to read and set
    /// from any thread (it's built for live automation), so the UI binds to
    /// these directly rather than routing through TapPipeline's work queue
    /// the way the other, non-thread-safe setters in this file do.
    var allControls: [SupermassiveControl] {
        (tree?.allParameters ?? []).map { SupermassiveControl(id: $0.address, param: $0) }
    }

    /// AVM's existing 0...100% Mix slider, routed to Supermassive's own Mix
    /// parameter instead of AVAudioUnitReverb.wetDryMix. Was setExact(0...100)
    /// until a real run showed even 1% playing fully wet: Supermassive's Mix
    /// parameter is apparently normalized (0.0...1.0, displayed as a %), so any
    /// slider value >= 1 was clamping straight to its maximum -- "1%" was
    /// actually sending 100% wet every time. Scaled as a fraction instead, like
    /// every other control here, so it no longer assumes the plugin's units
    /// match the UI's.
    func setMix(_ percent: Float) {
        setFraction(named: "mix", to: percent / 100, excluding: "lock")
    }

    func apply(_ preset: SupermassiveReverbPreset) {
        setMode(preset.mode)
        let f = preset.fractions
        setFraction(named: "width", to: f.width)
        setFraction(named: "delay", to: f.delay)
        setFraction(named: "warp", to: f.warp)
        setFraction(named: "feedback", to: f.feedback)
        setFraction(named: "density", to: f.density)
        setFraction(named: "mod rate", to: f.modRate)
        setFraction(named: "mod depth", to: f.modDepth)
        setFraction(named: "high cut", to: f.eqHighCut)
        setFraction(named: "low cut", to: f.eqLowCut)
    }

    // MARK: - Name-matched parameter access

    private func findParameter(containing needle: String, excluding: String? = nil) -> AUParameter? {
        guard let tree else { return nil }
        return tree.allParameters.first { param in
            let name = param.displayName.lowercased()
            guard name.contains(needle) else { return false }
            if let excluding, name.contains(excluding) { return false }
            return true
        }
    }

    private func setFraction(named needle: String, to fraction: Float, excluding: String? = nil) {
        guard let param = findParameter(containing: needle, excluding: excluding) else {
            warnMissing(needle)
            return
        }
        let clamped = min(max(fraction, 0), 1)
        param.value = param.minValue + clamped * (param.maxValue - param.minValue)
    }

    private func setMode(_ name: String) {
        guard let param = findParameter(containing: "mode") else {
            warnMissing("mode")
            return
        }
        guard let strings = param.valueStrings,
              let index = strings.firstIndex(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            dlog("Supermassive: Mode \"\(name)\" not among its valueStrings")
            return
        }
        param.value = Float(index)
    }

    /// Logs each missing parameter name once per instance, not once per call
    /// (setFraction/setExact run every time a preset is applied).
    private func warnMissing(_ needle: String) {
        guard !missingParameterNames.contains(needle) else { return }
        missingParameterNames.insert(needle)
        dlog("Supermassive: no parameter matching \"\(needle)\" — leaving it at its current value")
    }
}
