// Renders a 1024px "fire horse" app icon: a dark, left-facing horse silhouette
// webbed with glowing branching ember filaments (mane flaring up, tail sweeping
// down, flames off the hooves), bloomed on a dark squircle tile.
//   usage: xcrun swift scripts/fire-horse-icon.swift <out.png> [seed]
import AppKit
import CoreImage

// MARK: - Deterministic RNG (SplitMix64) so rebuilds are identical.
struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func f(_ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53) * (hi - lo) + lo
    }
}

// MARK: - Canvas
let S: CGFloat = 1024
let inset: CGFloat = 96          // artwork sits inside the macOS icon grid
let A = S - 2 * inset            // art square edge
func P(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {   // y-DOWN normalized → pixels
    CGPoint(x: inset + nx * A, y: inset + (1 - ny) * A)
}
func L(_ v: CGFloat) -> CGFloat { v * A }           // normalized length → pixels

let outPath = CommandLine.arguments.dropFirst().first ?? "build/fire-horse-1024.png"
let seed = UInt64(CommandLine.arguments.dropFirst(2).first.flatMap { UInt64($0) } ?? 20260825)

// MARK: - Silhouette primitives (contains / boundary / fill)
protocol Prim {
    func contains(_ p: CGPoint) -> Bool
    func boundary(_ n: Int) -> [CGPoint]
    func path() -> CGPath
    func fill(into ctx: CGContext)     // solid fill (independent sub-shapes)
}
extension Prim {
    // Default: fill the whole path in one shot. Fine for convex single subpaths.
    func fill(into ctx: CGContext) { ctx.addPath(path()); ctx.fillPath() }
}
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

struct Ellipse: Prim {
    let c: CGPoint; let rx: CGFloat; let ry: CGFloat; var rot: CGFloat = 0
    func contains(_ p: CGPoint) -> Bool {
        let dx = p.x - c.x, dy = p.y - c.y
        let x =  dx * cos(-rot) - dy * sin(-rot)
        let y =  dx * sin(-rot) + dy * cos(-rot)
        return (x * x) / (rx * rx) + (y * y) / (ry * ry) <= 1
    }
    func boundary(_ n: Int) -> [CGPoint] {
        (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n) * .pi * 2
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: c.x + x * cos(rot) - y * sin(rot),
                           y: c.y + x * sin(rot) + y * cos(rot))
        }
    }
    func path() -> CGPath {
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: [t].withUnsafeBufferPointer { $0.baseAddress })
    }
}

struct Capsule: Prim {           // stadium between a and b, end widths wa/wb
    let a: CGPoint; let b: CGPoint; let wa: CGFloat; let wb: CGFloat
    private var len: CGFloat { max(dist(a, b), 0.0001) }
    private var dir: CGPoint { CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len) }
    private var nrm: CGPoint { CGPoint(x: -dir.y, y: dir.x) }
    func contains(_ p: CGPoint) -> Bool {
        let proj = max(0, min(len, (p.x - a.x) * dir.x + (p.y - a.y) * dir.y))
        let c = CGPoint(x: a.x + dir.x * proj, y: a.y + dir.y * proj)
        let r = (wa + (wb - wa) * (proj / len)) / 2
        return dist(p, c) <= r
    }
    func boundary(_ n: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        for i in 0...n {
            let k = CGFloat(i) / CGFloat(n)
            let c = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
            let r = (wa + (wb - wa) * k) / 2
            pts.append(CGPoint(x: c.x + nrm.x * r, y: c.y + nrm.y * r))
            pts.append(CGPoint(x: c.x - nrm.x * r, y: c.y - nrm.y * r))
        }
        return pts
    }
    func path() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: a.x - wa / 2, y: a.y - wa / 2, width: wa, height: wa))
        p.addEllipse(in: CGRect(x: b.x - wb / 2, y: b.y - wb / 2, width: wb, height: wb))
        p.move(to: CGPoint(x: a.x + nrm.x * wa / 2, y: a.y + nrm.y * wa / 2))
        p.addLine(to: CGPoint(x: b.x + nrm.x * wb / 2, y: b.y + nrm.y * wb / 2))
        p.addLine(to: CGPoint(x: b.x - nrm.x * wb / 2, y: b.y - nrm.y * wb / 2))
        p.addLine(to: CGPoint(x: a.x - nrm.x * wa / 2, y: a.y - nrm.y * wa / 2))
        p.closeSubpath()
        return p
    }
    // Fill the two end caps and the connecting quad separately, so overlapping
    // subpaths can't cancel under the nonzero winding rule (which would punch
    // holes in the silhouette mask).
    func fill(into ctx: CGContext) {
        ctx.fillEllipse(in: CGRect(x: a.x - wa / 2, y: a.y - wa / 2, width: wa, height: wa))
        ctx.fillEllipse(in: CGRect(x: b.x - wb / 2, y: b.y - wb / 2, width: wb, height: wb))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: a.x + nrm.x * wa / 2, y: a.y + nrm.y * wa / 2))
        ctx.addLine(to: CGPoint(x: b.x + nrm.x * wb / 2, y: b.y + nrm.y * wb / 2))
        ctx.addLine(to: CGPoint(x: b.x - nrm.x * wb / 2, y: b.y - nrm.y * wb / 2))
        ctx.addLine(to: CGPoint(x: a.x - nrm.x * wa / 2, y: a.y - nrm.y * wa / 2))
        ctx.closePath(); ctx.fillPath()
    }
}

struct Poly: Prim {
    let v: [CGPoint]
    func contains(_ p: CGPoint) -> Bool {
        var inside = false; var j = v.count - 1
        for i in 0..<v.count {
            if (v[i].y > p.y) != (v[j].y > p.y),
               p.x < (v[j].x - v[i].x) * (p.y - v[i].y) / (v[j].y - v[i].y) + v[i].x { inside.toggle() }
            j = i
        }
        return inside
    }
    func boundary(_ n: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            for k in 0..<n { let t = CGFloat(k) / CGFloat(n)
                pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        return pts
    }
    func path() -> CGPath {
        let p = CGMutablePath(); p.addLines(between: v); p.closeSubpath(); return p
    }
}

// MARK: - Assemble the horse (normalized, y-down; left-facing, standing)
let horse: [Prim] = [
    // torso masses
    Ellipse(c: P(0.560, 0.560), rx: L(0.205), ry: L(0.140)),          // barrel
    Ellipse(c: P(0.445, 0.560), rx: L(0.090), ry: L(0.120)),          // chest
    Ellipse(c: P(0.710, 0.545), rx: L(0.135), ry: L(0.150)),          // hindquarter
    // neck (arched) + head + jaw
    Poly(v: [P(0.415, 0.520), P(0.318, 0.320), P(0.352, 0.250), P(0.560, 0.470)]),
    Capsule(a: P(0.300, 0.250), b: P(0.180, 0.392), wa: L(0.085), wb: L(0.052)), // head
    Ellipse(c: P(0.268, 0.335), rx: L(0.058), ry: L(0.062)),          // cheek/jaw
    // ears
    Poly(v: [P(0.262, 0.238), P(0.250, 0.150), P(0.298, 0.222)]),
    Poly(v: [P(0.300, 0.228), P(0.322, 0.150), P(0.334, 0.226)]),
    // legs (front pair, then hind pair) + hooves
    Capsule(a: P(0.470, 0.640), b: P(0.452, 0.848), wa: L(0.052), wb: L(0.040)),
    Capsule(a: P(0.548, 0.640), b: P(0.566, 0.848), wa: L(0.048), wb: L(0.038)),
    Capsule(a: P(0.700, 0.660), b: P(0.684, 0.760), wa: L(0.070), wb: L(0.050)),
    Capsule(a: P(0.684, 0.760), b: P(0.694, 0.848), wa: L(0.050), wb: L(0.040)),
    Capsule(a: P(0.778, 0.665), b: P(0.786, 0.848), wa: L(0.050), wb: L(0.038)),
    Ellipse(c: P(0.452, 0.856), rx: L(0.028), ry: L(0.018)),
    Ellipse(c: P(0.566, 0.856), rx: L(0.026), ry: L(0.018)),
    Ellipse(c: P(0.694, 0.856), rx: L(0.027), ry: L(0.018)),
    Ellipse(c: P(0.786, 0.856), rx: L(0.026), ry: L(0.018)),
    // tail root
    Capsule(a: P(0.815, 0.500), b: P(0.845, 0.640), wa: L(0.060), wb: L(0.040)),
]

func insideHorse(_ p: CGPoint) -> Bool { horse.contains { $0.contains(p) } }

// Silhouette outline = boundary samples not swallowed by another primitive.
var outline: [CGPoint] = []
for (i, prim) in horse.enumerated() {
    for q in prim.boundary(46) where !horse.enumerated().contains(where: { $0.offset != i && $0.element.contains(q) }) {
        outline.append(q)
    }
}

// horse bounding box (for interior sampling + fill gradient)
var minX = S, minY = S, maxX: CGFloat = 0, maxY: CGFloat = 0
for prim in horse { for q in prim.boundary(24) {
    minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y) } }

// MARK: - Fire palette (bright hot core → deep ember tip)
let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0.00, (1.00, 0.96, 0.80)),
    (0.18, (1.00, 0.78, 0.34)),
    (0.42, (1.00, 0.48, 0.09)),
    (0.70, (0.82, 0.22, 0.02)),
    (1.00, (0.34, 0.06, 0.01)),
]
func ember(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let t = max(0, min(1, t))
    for i in 1..<stops.count where t <= stops[i].0 {
        let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
        let k = (t - t0) / (t1 - t0)
        return (c0.0 + (c1.0 - c0.0) * k, c0.1 + (c1.1 - c0.1) * k, c0.2 + (c1.2 - c0.2) * k)
    }
    return stops.last!.1
}

// MARK: - Contexts
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func newCtx() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
var rng = RNG(seed)

// Draw one branching filament into `ctx` from `start`, heading `ang`, with buoyancy drift.
func filament(_ ctx: CGContext, _ start: CGPoint, ang: CGFloat, len: CGFloat, width: CGFloat,
              buoy: CGPoint, gens: Int, curl: CGFloat, alpha: CGFloat, branch: CGFloat = 0.13) {
    let step = L(0.007)
    let n = max(2, Int(len / step))
    var p = start, a = ang
    for i in 0..<n {
        a += rng.f(-curl, curl)
        let q = CGPoint(x: p.x + cos(a) * step + buoy.x * step,
                        y: p.y + sin(a) * step + buoy.y * step)
        let t = CGFloat(i) / CGFloat(n)
        let (r, g, b) = ember(t)
        ctx.setStrokeColor(CGColor(srgbRed: r, green: g, blue: b, alpha: alpha * (1 - t * 0.7)))
        ctx.setLineWidth(max(0.5, width * (1 - t * 0.7)))
        ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
        if gens > 0 && rng.f() < branch {
            filament(ctx, q, ang: a + (rng.f() < 0.5 ? 1 : -1) * rng.f(0.3, 0.8),
                     len: len * rng.f(0.35, 0.6), width: width * 0.7, buoy: buoy,
                     gens: gens - 1, curl: curl, alpha: alpha, branch: branch)
        }
        p = q
    }
}

// Silhouette mask: opaque warm-white horse, transparent outside — used to clip
// the body fire so the shape stays crisp.
let mask = newCtx()
mask.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
for prim in horse { prim.fill(into: mask) }
let maskImg = mask.makeImage()!

// MARK: - Body fire (clipped to the silhouette → a solid, horse-shaped glow)
let bodyFire = newCtx()
bodyFire.setLineCap(.round)
bodyFire.setBlendMode(.plusLighter)
// faint ember base fill so the mass is present even between filaments; drawn
// over the bounding box and clipped to the silhouette by the destinationIn pass.
bodyFire.saveGState()
bodyFire.clip(to: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
let baseFill = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.50, green: 0.19, blue: 0.05, alpha: 1),
    CGColor(srgbRed: 0.34, green: 0.12, blue: 0.03, alpha: 1),
] as CFArray, locations: [0, 1])!
bodyFire.drawLinearGradient(baseFill, start: CGPoint(x: 0, y: maxY),
                            end: CGPoint(x: 0, y: minY), options: [])
bodyFire.restoreGState()
// edge-hugging web — short, so it defines the outline instead of wandering off
for q in outline.shuffled() {
    filament(bodyFire, q, ang: rng.f(0, .pi * 2), len: L(rng.f(0.025, 0.06)),
             width: rng.f(1.1, 2.1), buoy: CGPoint(x: 0.04, y: 0.06), gens: 1, curl: 0.4,
             alpha: rng.f(0.34, 0.55))
}
// interior web — fills the body with texture
var placed = 0
while placed < 780 {
    let p = CGPoint(x: rng.f(minX, maxX), y: rng.f(minY, maxY))
    guard insideHorse(p) else { continue }
    placed += 1
    filament(bodyFire, p, ang: rng.f(0, .pi * 2), len: L(rng.f(0.02, 0.055)),
             width: rng.f(0.8, 1.6), buoy: CGPoint(x: 0.03, y: 0.05), gens: 1, curl: 0.5,
             alpha: rng.f(0.16, 0.34))
}
// clip everything above to the silhouette
bodyFire.setBlendMode(.destinationIn)
bodyFire.draw(maskImg, in: CGRect(x: 0, y: 0, width: S, height: S))
let bodyImg = bodyFire.makeImage()!

// MARK: - Flares (escape the silhouette): mane, forelock, tail, hooves
let flare = newCtx()
flare.setLineCap(.round)
flare.setBlendMode(.plusLighter)
// mane along crest: poll → withers → back toward croup
let crest = (0...64).map { i -> CGPoint in
    let t = CGFloat(i) / 64
    let a = P(0.352, 0.250), b = P(0.560, 0.470), c = P(0.792, 0.478)
    return t < 0.5 ? CGPoint(x: a.x + (b.x - a.x) * (t / 0.5), y: a.y + (b.y - a.y) * (t / 0.5))
                   : CGPoint(x: b.x + (c.x - b.x) * ((t - 0.5) / 0.5), y: b.y + (c.y - b.y) * ((t - 0.5) / 0.5))
}
for base in crest {
    for _ in 0..<2 {
        filament(flare, CGPoint(x: base.x + rng.f(-L(0.008), L(0.008)), y: base.y),
                 ang: rng.f(0.5, 1.2), len: L(rng.f(0.06, 0.15)), width: rng.f(1.2, 2.3),
                 buoy: CGPoint(x: 0.35, y: 0.75), gens: 2, curl: 0.45, alpha: rng.f(0.30, 0.5))
    }
}
// forelock between the ears
for _ in 0..<22 {
    filament(flare, P(0.294, 0.236), ang: rng.f(1.2, 2.1), len: L(rng.f(0.05, 0.11)),
             width: rng.f(1.0, 1.9), buoy: CGPoint(x: -0.15, y: 0.85), gens: 2, curl: 0.5,
             alpha: rng.f(0.3, 0.5))
}
// tail sweeping down and out to the right
for i in 0..<120 {
    let t = CGFloat(i) / 120
    let base = CGPoint(x: P(0.822, 0.520).x + L(0.028) * sin(t * 6),
                       y: P(0.822, 0.520).y - L(t * 0.32))
    filament(flare, base, ang: rng.f(-1.3, -0.5), len: L(rng.f(0.07, 0.17)),
             width: rng.f(1.0, 2.1), buoy: CGPoint(x: 0.3, y: -0.85), gens: 2, curl: 0.45,
             alpha: rng.f(0.26, 0.46))
}
// flames licking up off the hooves
for hoof in [P(0.452, 0.860), P(0.566, 0.860), P(0.694, 0.860), P(0.786, 0.860)] {
    for _ in 0..<34 {
        filament(flare, CGPoint(x: hoof.x + rng.f(-L(0.025), L(0.025)), y: hoof.y),
                 ang: rng.f(1.2, 1.9), len: L(rng.f(0.03, 0.09)), width: rng.f(1.0, 2.0),
                 buoy: CGPoint(x: rng.f(-0.15, 0.15), y: 1.0), gens: 1, curl: 0.55,
                 alpha: rng.f(0.28, 0.48))
    }
}
let flareImg = flare.makeImage()!

// Bloom = blur(body + flare). Content sits well inside the frame, so a plain
// blur (no edge clamp) avoids smearing anything toward the borders.
let glowSrc = newCtx()
glowSrc.draw(bodyImg, in: CGRect(x: 0, y: 0, width: S, height: S))
glowSrc.setBlendMode(.plusLighter)
glowSrc.draw(flareImg, in: CGRect(x: 0, y: 0, width: S, height: S))
let ci = CIContext(options: [.workingColorSpace: cs])
let blurred = CIImage(cgImage: glowSrc.makeImage()!)
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: S * 0.011])
let glowImg = ci.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: S, height: S))!

// MARK: - Compose the final icon
let out = newCtx()
let tile = CGPath(roundedRect: CGRect(x: inset, y: inset, width: A, height: A),
                  cornerWidth: 185, cornerHeight: 185, transform: nil)
out.addPath(tile); out.clip()

// dark tile: warm radial glow behind the horse fading to near-black
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.12, green: 0.09, blue: 0.06, alpha: 1),
    CGColor(srgbRed: 0.045, green: 0.03, blue: 0.022, alpha: 1),
    CGColor(srgbRed: 0.014, green: 0.010, blue: 0.010, alpha: 1),
] as CFArray, locations: [0, 0.55, 1])!
out.drawRadialGradient(bg, startCenter: P(0.55, 0.52), startRadius: 0,
                       endCenter: P(0.55, 0.52), endRadius: A * 0.72, options: [])

// dark horse body underneath, so the fire reads against a solid mass
let body = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.14, green: 0.07, blue: 0.03, alpha: 1),
    CGColor(srgbRed: 0.035, green: 0.016, blue: 0.010, alpha: 1),
] as CFArray, locations: [0, 1])!
for prim in horse {
    out.saveGState(); out.addPath(prim.path()); out.clip()
    out.drawLinearGradient(body, start: CGPoint(x: 0, y: maxY), end: CGPoint(x: 0, y: minY), options: [])
    out.restoreGState()
}

out.setBlendMode(.plusLighter)
out.draw(glowImg, in: CGRect(x: 0, y: 0, width: S, height: S))    // bloom
out.draw(bodyImg, in: CGRect(x: 0, y: 0, width: S, height: S))    // crisp horse-shaped fire
out.draw(flareImg, in: CGRect(x: 0, y: 0, width: S, height: S))   // crisp mane/tail/hoof flares

// Sparks — tiny hot dots, mostly along the edge and through the flares
for _ in 0..<360 {
    let onEdge = rng.f() < 0.7
    let p = onEdge ? outline.randomElement()! : CGPoint(x: rng.f(minX, maxX), y: rng.f(minY, maxY))
    if !onEdge && !insideHorse(p) { continue }
    let (r, g, b) = ember(rng.f(0, 0.35))
    out.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: rng.f(0.4, 0.9)))
    let s = rng.f(1.2, 2.8)
    out.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
}

let final = out.makeImage()!
let rep = NSBitmapImageRep(cgImage: final)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
