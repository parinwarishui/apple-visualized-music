//
//  TankMotion.swift
//  How things move in each visualizer style: the water drops' wobble, the
//  rain's ripples, and the fish tank's fish, seaweed, coral and bubbles. Pure
//  value code
//  (positions are 0...1 of the tank, or points for a given size), unit-tested.
//  Drawing is in TankScenes.swift.
//

import CoreGraphics
import Foundation

/// The visualizer styles, picked from the menu under the tank.
enum TankMode: String, CaseIterable, Identifiable {
    case bokeh, drops, rain, fish

    var id: Self { self }

    /// How strongly Focus blurs this style. Small or thin things vanish under a
    /// blur that suits big soft shapes, so each style gets one that looks about
    /// as hazy as the others at the same slider position.
    var blurAmount: Double {
        switch self {
        case .bokeh: return 0.4
        case .drops: return 0.6
        case .rain: return 0.28
        case .fish: return 0.35
        }
    }

    var title: String {
        switch self {
        case .bokeh: return "Bokeh"
        case .drops: return "Water drops"
        case .rain: return "Rain"
        case .fish: return "Fish"
        }
    }
}

/// A repeatable 0..<1 number for `index`, so "random" drops and wobbles look the
/// same every time they're drawn at the same moment (SplitMix64).
func tankHash(_ index: Int, salt: UInt64 = 0) -> Double {
    var z = UInt64(bitPattern: Int64(index)) &+ (salt &+ 1) &* 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(UInt64(1) << 53)
}

// MARK: - Water drops

/// A water drop drawn as overlapping circles that are blurred together and cut
/// at half opacity, so they merge like liquid with surface tension. Lobes
/// orbiting the core reshape the drop all the time; a satellite droplet drifts
/// off, pinches away and rejoins.
enum DropShape {
    struct Circle: Equatable {
        var center: CGPoint
        var radius: CGFloat
    }

    static let lobeCount = 4
    /// How long a satellite droplet takes to break away and come back.
    static let satellitePeriod = 9.0

    /// `splash` (0...1, a kick) throws the lobes outward.
    static func circles(center: CGPoint, radius: CGFloat, time: Double, seed: Double,
                        splash: Double) -> [Circle] {
        var circles = [Circle(center: center, radius: radius * 0.62)]
        for j in 0..<lobeCount {
            let k = Double(j)
            let angle = seed * 7 + k * .pi / 2 + 0.8 * sin(time * (0.35 + 0.11 * k) + seed + k)
            let reach = radius * CGFloat((0.36 + 0.16 * sin(time * (0.6 + 0.17 * k) + seed * 3 + k)) * (1 + 0.45 * splash))
            let size = radius * CGFloat(0.42 + 0.07 * sin(time * (0.5 + 0.13 * k) + seed * k))
            circles.append(Circle(center: CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle)),
                                  radius: size))
        }
        // The satellite: sits inside, drifts out until it pinches off, drifts back.
        let phase = (time / satellitePeriod + seed).truncatingRemainder(dividingBy: 1)
        let out = pow(sin(.pi * phase), 2)
        let angle = seed * 11 + time * 0.15
        let reach = radius * CGFloat(0.5 + 1.0 * out)
        circles.append(Circle(center: CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle)),
                              radius: radius * 0.2))
        return circles
    }
}

// MARK: - Rain

/// One raindrop's ripple on the water.
struct Ripple: Equatable {
    /// Where it landed, 0...1 of the tank.
    var x: Double
    var y: Double
    /// When it landed (tank time).
    var born: Double
    var band: TankBand
    /// 0...1: how big and bright its rings get.
    var strength: Double

    struct Ring: Equatable {
        var radius: CGFloat
        var opacity: Double
        var lineWidth: CGFloat
    }

    static let lifetime = 2.6
    static let ringCount = 4

    /// The rings at `time`, outermost first: they spread fast, then slow, and
    /// fade as they go. Empty before the drop lands and after it has died away.
    func rings(at time: Double, scale: CGFloat) -> [Ring] {
        let age = time - born
        guard age >= 0, age < Self.lifetime else { return [] }
        let progress = age / Self.lifetime
        let reach = scale * CGFloat(0.30 + 0.62 * strength) * CGFloat(pow(progress, 0.55))
        let fade = pow(1 - progress, 1.6) * (0.45 + 0.55 * strength)
        return (0..<Self.ringCount).compactMap { k in
            let radius = reach * (1 - 0.22 * CGFloat(k))
            guard radius > 1 else { return nil }
            return Ring(radius: radius, opacity: fade * (1 - 0.25 * Double(k)),
                        lineWidth: CGFloat(1.5 + 4.5 * (1 - progress)))
        }
    }
}

/// The rain: steady drops whose rate follows the song's loudness, a big drop on
/// each kick and a small one on each hi-hat. Stateful (drops land on hits), so
/// it lives in the tank model. Seeded, so tests can replay it.
struct RainField: Equatable {
    static let maxRipples = 48

    private(set) var ripples: [Ripple] = []
    private var seed: UInt64
    /// Drops owed so far: the rate is fractional, so whole drops land as it adds up.
    private var owed = 0.0

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.seed = seed
    }

    /// Steady drops per second at a song tone (0 quiet ... 1 loud).
    static func dropsPerSecond(songTone: Double) -> Double {
        0.8 + 5 * pow(min(max(songTone, 0), 1), 2)
    }

    mutating func update(time: Double, dt: Double, songTone: Double, kick: Bool, hat: Bool) {
        ripples.removeAll { time - $0.born >= Ripple.lifetime }
        owed += Self.dropsPerSecond(songTone: songTone) * dt
        while owed >= 1 {
            owed -= 1
            land(time: time, band: .song, strength: 0.2 + 0.35 * random())
        }
        if kick { land(time: time, band: .bass, strength: 1) }
        if hat { land(time: time, band: .treble, strength: 0.45) }
        if ripples.count > Self.maxRipples { ripples.removeFirst(ripples.count - Self.maxRipples) }
    }

    private mutating func land(time: Double, band: TankBand, strength: Double) {
        ripples.append(Ripple(x: 0.08 + 0.84 * random(), y: 0.08 + 0.84 * random(),
                              born: time, band: band, strength: strength))
    }

    private mutating func random() -> Double {
        seed &+= 1
        return tankHash(Int(bitPattern: UInt(truncatingIfNeeded: seed)), salt: 99)
    }
}

// MARK: - Fish

/// The fish tank: a school of fish in the band colours, seaweed and coral along
/// the bottom, and bubbles rising. Every position is a pure function of time.
enum FishTank {
    struct Fish {
        var band: TankBand
        /// Body length, as a share of the tank scale (`TankBlobs.scale`).
        var length: Double
        /// Seeds this fish's path, timing and tail beat.
        var seed: Int
    }

    /// Four fish per band: bass fish the biggest, treble the smallest, each a
    /// little different.
    static let school: [Fish] = TankBand.allCases.enumerated().flatMap { bandIndex, band -> [Fish] in
        let base: Double = band == .bass ? 0.16 : band == .song ? 0.12 : 0.085
        return (0..<4).map { k in
            let seed = bandIndex * 4 + k
            return Fish(band: band, length: base * (0.75 + 0.5 * tankHash(seed, salt: 40)), seed: seed)
        }
    }

    /// Where the fish swim, 0...1 of the tank: above the seaweed, clear of the edges.
    static let swimArea = CGRect(x: 0.08, y: 0.10, width: 0.84, height: 0.62)

    /// A fish's position (0...1 of the tank). Unpredictable but calculated: each
    /// axis is two slow waves with periods in an irrational ratio (so the path
    /// never repeats), run on a clock that speeds up and slows down (so the fish
    /// dart and drift). The warp's slope stays positive, so a fish never swims
    /// backwards in time.
    static func position(of fish: Fish, time t: Double) -> CGPoint {
        let h = { (salt: UInt64) in tankHash(fish.seed, salt: salt) }
        let warp = t + 2.4 * sin(t / (6 + 4 * h(41)) + 6.28 * h(42))
        // Vertical waves are slower than horizontal ones, so fish mostly cruise
        // across the tank and rise or sink gently, as real fish do.
        let px = 24 + 26 * h(43), py = 2.1 * px * (0.85 + 0.3 * h(44))
        let x = 0.62 * sin(2 * .pi * warp / px + 6.28 * h(45)) + 0.38 * sin(2 * .pi * warp / (px * 0.618) + 6.28 * h(46))
        let y = 0.62 * sin(2 * .pi * warp / py + 6.28 * h(47)) + 0.38 * sin(2 * .pi * warp / (py * 1.414) + 6.28 * h(48))
        return CGPoint(x: swimArea.midX + swimArea.width / 2 * x,
                       y: swimArea.midY + swimArea.height / 2 * y)
    }

    /// How far a fish tilts nose up or down, at most (radians, about 30°).
    static let maxTilt = 0.52

    /// Which way a fish faces for a movement (dx, dy in points): along it, with
    /// the tilt capped, and whether it's swimming left (drawn mirrored).
    static func facing(dx: Double, dy: Double) -> (tilt: Double, left: Bool) {
        let left = dx < 0
        let tilt = atan2(dy, abs(dx))
        return (min(max(tilt, -maxTilt), maxTilt), left)
    }

    /// How strongly a fish glows, 0 resting ... 1 full. Bass and treble fish
    /// flare on each kick or hi-hat (the same pulse that swells the other
    /// styles' shapes, so just as quick); song fish glow with the song's
    /// loudness above its usual level.
    static func glow(band: TankBand, tone: Double, hit: Double) -> Double {
        let value = band == .song ? (tone - 0.35) / 0.5 : hit
        return min(max(value, 0), 1)
    }

    /// Brightness of a resting fish, as a share of its full colour.
    static let restBrightness = 0.45
    /// How far towards white a fully glowing fish goes.
    static let peakWhite = 0.45

    /// A fish's colour: dim at rest, its full cover colour at half glow, most of
    /// the way to white at full glow, so a flare is obvious.
    static func color(_ base: RGB, glow: Double) -> RGB {
        let full = base.value < 0.65 ? base.scaled(by: 0.65 / max(base.value, 0.01)) : base   // dark covers still show
        if glow < 0.5 {
            return full.scaled(by: restBrightness + (1 - restBrightness) * glow * 2)
        }
        return full.mixed(with: .white, amount: peakWhite * (glow - 0.5) * 2)
    }

    /// The tail's swing in radians: faster when the fish is swimming faster.
    static func tailSwing(of fish: Fish, time t: Double, speed: Double) -> Double {
        0.45 * sin(t * (5 + 40 * min(speed, 0.25)) + 6.28 * tankHash(fish.seed, salt: 49))
    }

    // Seaweed

    struct Strand {
        /// Root position across the tank, 0...1.
        var x: Double
        /// Height as a share of the tank's height.
        var height: Double
        var band: TankBand
        var seed: Int
    }

    static let seaweed: [Strand] = (0..<11).map { i in
        Strand(x: (Double(i) + 0.2 + 0.6 * tankHash(i, salt: 50)) / 11,
               height: 0.12 + 0.18 * tankHash(i, salt: 51),
               band: TankBand.allCases[i % 3], seed: i)
    }

    /// Points up a strand, root first, swaying more towards the tip. `sway`
    /// (0...1, the song's loudness) makes it sway further.
    static func strandPoints(_ strand: Strand, time t: Double, sway: Double, in size: CGSize,
                             segments: Int = 14) -> [CGPoint] {
        let root = CGPoint(x: strand.x * size.width, y: size.height)
        let length = strand.height * size.height
        let phase = 6.28 * tankHash(strand.seed, salt: 52)
        let reach = length * (0.12 + 0.10 * sway)
        return (0...segments).map { k in
            let u = Double(k) / Double(segments)
            let bend = pow(u, 1.6) * (sin(t * 0.7 + phase - u * 2.2) + 0.35 * sin(t * 1.9 + phase * 2 - u * 4))
            return CGPoint(x: root.x + reach * bend, y: root.y - length * u)
        }
    }

    // Coral

    struct Coral {
        var x: Double
        var size: Double
        var band: TankBand
        var seed: Int
    }

    static let corals: [Coral] = (0..<5).map { i in
        Coral(x: (Double(i) + 0.5 + 0.3 * (tankHash(i, salt: 53) - 0.5)) / 5,
              size: 0.09 + 0.06 * tankHash(i, salt: 54),
              band: TankBand.allCases[(i + 1) % 3], seed: i)
    }

    struct Branch: Equatable {
        var from: CGPoint
        var to: CGPoint
        var width: CGFloat
    }

    /// A coral as a fan of thick rounded branches from one root on the bottom,
    /// each with a short twig (points). Fixed for each coral.
    static func coralBranches(_ coral: Coral, scale: Double, in size: CGSize) -> [Branch] {
        let reach = coral.size * scale * 1.4
        let root = CGPoint(x: coral.x * size.width, y: size.height)
        let width = CGFloat(coral.size * scale * 0.32)
        return (0..<5).flatMap { j -> [Branch] in
            let h = { (salt: UInt64) in tankHash(coral.seed * 5 + j, salt: salt) }
            let angle = -Double.pi / 2 + (Double(j) - 2) * 0.38 + 0.15 * (h(55) - 0.5)   // straight up is -π/2
            let length = reach * (0.55 + 0.45 * h(60))
            let tip = CGPoint(x: root.x + length * cos(angle), y: root.y + length * sin(angle))
            let fork = CGPoint(x: root.x + 0.6 * length * cos(angle), y: root.y + 0.6 * length * sin(angle))
            let twigAngle = angle + (h(61) < 0.5 ? -0.6 : 0.6)
            let twig = CGPoint(x: fork.x + 0.35 * length * cos(twigAngle), y: fork.y + 0.35 * length * sin(twigAngle))
            return [Branch(from: root, to: tip, width: width),
                    Branch(from: fork, to: twig, width: width * 0.75)]
        }
    }

    // Bubbles

    struct Bubble: Equatable {
        /// 0...1 of the tank.
        var position: CGPoint
        /// 0 just released, 1 at the surface.
        var age: Double
        /// Radius, as a share of the tank scale.
        var radius: Double
    }

    static let bubblesPerSecond = 1.6
    static let bubbleLife = 8.0

    /// Bubbles alive at `time`: each released from the bottom at a steady rate
    /// at a spot fixed by its index, rising and wobbling to the surface.
    static func bubbles(time t: Double) -> [Bubble] {
        let first = Int(floor((t - bubbleLife) * bubblesPerSecond)) + 1
        let last = Int(floor(t * bubblesPerSecond))
        guard last >= first else { return [] }
        return (first...last).map { i in
            let born = Double(i) / bubblesPerSecond
            let age = (t - born) / bubbleLife
            let x0 = 0.06 + 0.88 * tankHash(i, salt: 56)
            let wobble = 0.012 * sin((t - born) * (1.6 + tankHash(i, salt: 57)) + 6.28 * tankHash(i, salt: 58))
            return Bubble(position: CGPoint(x: x0 + wobble, y: 1.02 - 1.06 * age),
                          age: age,
                          radius: 0.006 + 0.012 * tankHash(i, salt: 59))
        }
    }
}

