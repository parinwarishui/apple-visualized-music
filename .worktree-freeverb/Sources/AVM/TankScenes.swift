//
//  TankScenes.swift
//  Drawing for each visualizer style. Every scene draws into one layer that the
//  tank screen-blends onto its water (and blurs, for Focus); the water, vignette
//  and glass are shared and drawn by `TankView`. Motion comes from TankMotion.swift.
//

import SwiftUI

/// How a band looks right now: the song swells with loudness, bass and treble
/// rest dim and lift and swell on each hit.
struct BandLook {
    var tone: Double
    /// Size multiplier from loudness and the latest hit.
    var scale: Double
    var hit: Double
    var color: Color

    init(_ band: TankBand, in frame: TankModel.Frame) {
        hit = frame.hits[band]
        let level = frame.tones[band]
        tone = band == .song ? level : TankTone.hitTone(level: level, hit: hit)
        scale = TankTone.radiusScale(tone: tone) * (1 + band.hitSwell * hit)
        color = TankTone.blobColor(frame.palette.color(for: band), tone: tone).color
    }
}

enum TankScenes {
    static func draw(_ mode: TankMode, _ frame: TankModel.Frame, core: Double,
                     in layer: inout GraphicsContext, size: CGSize) {
        let looks = Dictionary(uniqueKeysWithValues: TankBand.allCases.map { ($0, BandLook($0, in: frame)) })
        switch mode {
        case .bokeh: bokeh(frame, looks, core: core, in: &layer, size: size)
        case .drops: drops(frame, looks, in: &layer, size: size)
        case .rain: rain(frame, looks, in: &layer, size: size)
        case .fish: fish(frame, looks, in: &layer, size: size)
        }
    }

    // MARK: Bokeh

    /// Bokeh discs' size, relative to their blob's radius.
    static let bokehSize = 0.25
    /// The share of a disc that's solid colour before its edge fades, at
    /// standard focus; sharper focus widens it further (`core`).
    static let bokehSolid = 0.5

    /// Out-of-focus discs of light, like bokeh in a photo: many small ones (three
    /// per blob), each with a solid middle and a short soft edge.
    private static func bokeh(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook], core: Double,
                              in layer: inout GraphicsContext, size: CGSize) {
        for blob in TankBlobs.bokehLayout(time: frame.time, in: size) {
            let look = looks[blob.band]!
            let radius = blob.radius * bokehSize * look.scale
            let opacity = TankTone.opacity(blob.opacity, tone: look.tone)
            let solid = bokehSolid + (1 - bokehSolid) * core
            let gradient = Gradient(stops: [
                .init(color: look.color.opacity(opacity), location: 0),
                .init(color: look.color.opacity(opacity), location: solid),
                .init(color: look.color.opacity(opacity * 0.35), location: solid + (1 - solid) * 0.55),
                .init(color: look.color.opacity(0), location: 1)
            ])
            layer.fill(Path(ellipseIn: circle(blob.center, radius)),
                       with: .radialGradient(gradient, center: blob.center, startRadius: 0, endRadius: radius))
        }
    }

    // MARK: Water drops

    /// One drop per blob. Each band's drops are blurred together and cut at half
    /// opacity, so its two drops merge and split like liquid where they meet.
    private static func drops(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook],
                              in layer: inout GraphicsContext, size: CGSize) {
        let blobs = Array(TankBlobs.layout(time: frame.time, in: size).enumerated())
        let goo = TankBlobs.scale(of: size) * 0.05
        for band in TankBand.allCases {
            let look = looks[band]!
            layer.drawLayer { drops in
                drops.addFilter(.alphaThreshold(min: 0.5, color: look.color.opacity(0.85)))
                drops.addFilter(.blur(radius: goo))
                drops.drawLayer { inner in
                    for (index, blob) in blobs where blob.band == band {
                        let radius = blob.radius * 0.52 * look.scale
                        for c in DropShape.circles(center: blob.center, radius: radius, time: frame.time,
                                                   seed: Double(index) * 1.618, splash: look.hit) {
                            inner.fill(Path(ellipseIn: circle(c.center, c.radius)), with: .color(.white))
                        }
                    }
                }
            }
        }
    }

    // MARK: Rain

    /// Rings spreading on the water where drops land: the song's steady rain,
    /// a big drop on each kick, a small one on each hi-hat.
    private static func rain(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook],
                             in layer: inout GraphicsContext, size: CGSize) {
        let scale = TankBlobs.scale(of: size)
        for ripple in frame.ripples {
            let look = looks[ripple.band]!
            let center = CGPoint(x: ripple.x * size.width, y: ripple.y * size.height)
            for ring in ripple.rings(at: frame.time, scale: scale) {
                layer.stroke(Path(ellipseIn: circle(center, ring.radius)),
                             with: .color(look.color.opacity(ring.opacity)), lineWidth: ring.lineWidth)
            }
            // The splash where it lands, gone in a moment.
            let age = frame.time - ripple.born
            if age >= 0, age < 0.2 {
                let radius = scale * 0.035 * CGFloat(0.6 + ripple.strength)
                layer.fill(Path(ellipseIn: circle(center, radius)), with: .color(.white.opacity(0.8 * (1 - age / 0.2))))
            }
        }
    }

    // MARK: Fish

    /// A fish tank: coral and swaying seaweed along the bottom, bubbles rising,
    /// and a school of fish in the band colours. A fish's colour flares with its
    /// band (the song's loudness, or a kick or hi-hat); its size never changes.
    private static func fish(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook],
                             in layer: inout GraphicsContext, size: CGSize) {
        let scale = TankBlobs.scale(of: size)
        let palette = frame.palette
        let t = frame.time
        /// The bottom's colours: the band colours sunk a little into the water.
        func scenery(_ band: TankBand) -> Color {
            palette.color(for: band).mixed(with: palette.water, amount: 0.45).color
        }

        for coral in FishTank.corals {
            var branches = layer
            branches.opacity = 0.8   // overlapping branches share one colour instead of brightening
            branches.drawLayer { coralLayer in
                for branch in FishTank.coralBranches(coral, scale: scale, in: size) {
                    var line = Path()
                    line.move(to: branch.from)
                    line.addLine(to: branch.to)
                    coralLayer.stroke(line, with: .color(scenery(coral.band)),
                                      style: StrokeStyle(lineWidth: branch.width, lineCap: .round))
                }
            }
        }

        let sway = looks[.song]!.tone
        let strandWidth = max(2, scale * 0.012)
        for strand in FishTank.seaweed {
            var path = Path()
            path.addLines(FishTank.strandPoints(strand, time: t, sway: sway, in: size))
            layer.stroke(path, with: .color(scenery(strand.band).opacity(0.85)),
                         style: StrokeStyle(lineWidth: strandWidth, lineCap: .round, lineJoin: .round))
        }

        let treble = looks[.treble]!.hit
        for bubble in FishTank.bubbles(time: t) {
            let center = CGPoint(x: bubble.position.x * size.width, y: bubble.position.y * size.height)
            let radius = CGFloat(bubble.radius * scale)
            let fade = pow(max(0, 1 - bubble.age), 0.5) * (0.6 + 0.3 * treble)
            layer.stroke(Path(ellipseIn: circle(center, radius)), with: .color(.white.opacity(fade)),
                         lineWidth: max(1, radius * 0.18))
        }

        for fish in FishTank.school {
            let look = looks[fish.band]!
            let glow = FishTank.glow(band: fish.band, tone: frame.tones[fish.band], hit: look.hit)
            let base = palette.color(for: fish.band)
            func point(_ time: Double) -> CGPoint {
                let p = FishTank.position(of: fish, time: time)
                return CGPoint(x: p.x * size.width, y: p.y * size.height)
            }
            let center = point(t)
            let ahead = point(t + 0.15), behind = point(t - 0.15)
            let facing = FishTank.facing(dx: ahead.x - behind.x, dy: ahead.y - behind.y)
            let speed = hypot(ahead.x - behind.x, ahead.y - behind.y) / 0.3 / scale
            let length = fish.length * scale

            var body = layer
            body.translateBy(x: center.x, y: center.y)
            // Drawn facing right; swimming left, it's mirrored, so it never turns upside down.
            if facing.left { body.scaleBy(x: -1, y: 1) }
            body.rotate(by: .radians(facing.tilt))
            drawFish(length: length, swing: FishTank.tailSwing(of: fish, time: t, speed: speed),
                     color: FishTank.color(base, glow: glow).color, in: &body)
        }
    }

    /// A minimal fish pointing right, centred on the origin: an oval body, a
    /// forked tail that swings from the body's back, and an eye. Body and tail
    /// are one shape filled once, so where they meet isn't painted twice (with
    /// screen blending, an overlap would show as a brighter patch).
    private static func drawFish(length L: CGFloat, swing: Double, color: Color, in context: inout GraphicsContext) {
        let body = Path(ellipseIn: CGRect(x: -0.30 * L, y: -0.21 * L, width: 0.78 * L, height: 0.42 * L))
        var fin = Path()
        fin.move(to: CGPoint(x: 0.04 * L, y: 0))   // tucked just inside the body, so they join without a gap
        fin.addLine(to: CGPoint(x: -0.30 * L, y: -0.20 * L))
        fin.addQuadCurve(to: CGPoint(x: -0.30 * L, y: 0.20 * L), control: CGPoint(x: -0.18 * L, y: 0))
        fin.closeSubpath()
        // The tail pivots where it leaves the body.
        let pivot = CGAffineTransform(translationX: -0.26 * L, y: 0).rotated(by: CGFloat(swing))
        context.fill(body.union(fin.applying(pivot)), with: .color(color.opacity(0.92)))

        context.fill(Path(ellipseIn: circle(CGPoint(x: 0.30 * L, y: -0.05 * L), 0.035 * L)),
                     with: .color(.white.opacity(0.75)))
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
