// BridgeServiceMarks.swift — Real branded service marks for the Connections grid.
// v3.7.6 Wave 4b. Replaces the generic SF Symbols (circle.grid.2x2.fill /
// creditcard.fill) in ConnectionsSection's integration tiles with the ACTUAL
// branded logos so the pane reads as premium / built-in.
//
// SOURCING — the path `d=` data below is the OFFICIAL single-path mark for each
// brand as curated by simple-icons (https://github.com/simple-icons/simple-icons,
// MIT; icon data is the respective brand owner's). Both are viewBox 0 0 24 24:
//   • Notion → the stylized "N" mark (raw: icons/notion.svg). MONOCHROME, so it
//     is rendered with an ADAPTIVE BridgeTokens ink (near-black on the titanium
//     light canvas, near-white on the carbon dark canvas) to match the system
//     appearance — exactly how Notion's own monochrome mark is meant to behave.
//   • Stripe → the stylized "S" mark (raw: icons/stripe.svg). Rendered in
//     Stripe brand purple #635BFF.
//
// RENDERING — rather than ship a hand-authored PDF imageset (writing valid PDF
// bytes by hand is brittle and unreviewable), the official `d=` strings are
// consumed verbatim by a tiny, dependency-free SVG path parser (`SVGPath`) that
// emits a SwiftUI `Path`. This keeps the marks resolution-independent (true
// vectors, like a "Preserves Vector Data" PDF), faithful to the official source
// (no approximation — the literal published path data), and fully reviewable in
// source. The parser supports the command set these two paths use (M/m, L/l,
// H/h, V/v, C/c, S/s, Z/z), which covers both marks' cubic-Bézier outlines.

import SwiftUI

// MARK: - Public service-mark views

/// The official Notion "N" mark. Monochrome → adaptive ink that tracks the
/// system appearance (dark ink on light canvas, light ink on dark canvas).
public struct NotionMark: View {
    /// Override the fill; defaults to the appearance-adaptive ink token.
    public var tint: Color = BridgeServiceMarkTokens.notionInk
    public init(tint: Color = BridgeServiceMarkTokens.notionInk) { self.tint = tint }

    public var body: some View {
        SVGShape(path: BridgeServiceMarkPaths.notion)
            .fill(tint)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Notion")
    }
}

/// The official Stripe "S" mark in Stripe brand purple (#635BFF).
public struct StripeMark: View {
    /// Override the fill; defaults to Stripe brand purple.
    public var tint: Color = BridgeServiceMarkTokens.stripePurple
    public init(tint: Color = BridgeServiceMarkTokens.stripePurple) { self.tint = tint }

    public var body: some View {
        SVGShape(path: BridgeServiceMarkPaths.stripe)
            .fill(tint)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Stripe")
    }
}

// MARK: - Mark tokens

public enum BridgeServiceMarkTokens {
    /// Stripe brand purple — #635BFF (official brand mark color).
    public static let stripePurple = Color(red: 0.388, green: 0.357, blue: 1.0) // #635BFF

    /// Notion's mark is monochrome; follow the system appearance via the shared
    /// adaptive plumbing. Near-black ink on the titanium light canvas,
    /// near-white ink on the carbon dark canvas (mirrors fg1's intent but at
    /// full mark opacity so the glyph reads as a solid logo, not body text).
    public static let notionInk = BridgeTokens.adaptive(
        dark:  { BridgeTokens.whiteAlpha(0.95) },  // light mark on carbon
        light: { BridgeTokens.blackAlpha(0.92) }   // dark mark on titanium
    )
}

// MARK: - Official path data (verbatim from simple-icons, viewBox 0 0 24 24)

enum BridgeServiceMarkPaths {
    /// Official Notion "N" mark.
    static let notion = "M4.459 4.208c.746.606 1.026.56 2.428.466l13.215-.793c.28 0 .047-.28-.046-.326L17.86 1.968c-.42-.326-.981-.7-2.055-.607L3.01 2.295c-.466.046-.56.28-.374.466zm.793 3.08v13.904c0 .747.373 1.027 1.214.98l14.523-.84c.841-.046.935-.56.935-1.167V6.354c0-.606-.233-.933-.748-.887l-15.177.887c-.56.047-.747.327-.747.933zm14.337.745c.093.42 0 .84-.42.888l-.7.14v10.264c-.608.327-1.168.514-1.635.514-.748 0-.935-.234-1.495-.933l-4.577-7.186v6.952L12.21 19s0 .84-1.168.84l-3.222.186c-.093-.186 0-.653.327-.746l.84-.233V9.854L7.822 9.76c-.094-.42.14-1.026.793-1.073l3.456-.233 4.764 7.279v-6.44l-1.215-.139c-.093-.514.28-.887.747-.933zM1.936 1.035l13.31-.98c1.634-.14 2.055-.047 3.082.7l4.249 2.986c.7.513.934.653.934 1.213v16.378c0 1.026-.373 1.634-1.68 1.726l-15.458.934c-.98.047-1.448-.093-1.962-.747l-3.129-4.06c-.56-.747-.793-1.306-.793-1.96V2.667c0-.839.374-1.54 1.447-1.632z"

    /// Official Stripe "S" mark.
    static let stripe = "M13.976 9.15c-2.172-.806-3.356-1.426-3.356-2.409 0-.831.683-1.305 1.901-1.305 2.227 0 4.515.858 6.09 1.631l.89-5.494C18.252.975 15.697 0 12.165 0 9.667 0 7.589.654 6.104 1.872 4.56 3.147 3.757 4.992 3.757 7.218c0 4.039 2.467 5.76 6.476 7.219 2.585.92 3.445 1.574 3.445 2.583 0 .98-.84 1.545-2.354 1.545-1.875 0-4.965-.921-6.99-2.109l-.9 5.555C5.175 22.99 8.385 24 11.714 24c2.641 0 4.843-.624 6.328-1.813 1.664-1.305 2.525-3.236 2.525-5.732 0-4.128-2.524-5.851-6.594-7.305h.003z"
}

// MARK: - SVG path → SwiftUI Path

/// A SwiftUI `Shape` that renders an SVG path string, scaled to fit `rect`
/// from its declared `viewBox` (default 24×24, the simple-icons grid).
struct SVGShape: Shape, @unchecked Sendable {
    let path: String
    var viewBox: CGSize = CGSize(width: 24, height: 24)

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.parse(path)
        let sx = rect.width / viewBox.width
        let sy = rect.height / viewBox.height
        // Uniform scale (paths are square 24×24) + center within rect.
        let scale = min(sx, sy)
        let tx = rect.minX + (rect.width  - viewBox.width  * scale) / 2
        let ty = rect.minY + (rect.height - viewBox.height * scale) / 2
        let transform = CGAffineTransform(translationX: tx, y: ty)
            .scaledBy(x: scale, y: scale)
        return raw.applying(transform)
    }
}

/// Minimal, dependency-free SVG `d=` parser. Supports the absolute/relative
/// command set used by the bundled marks: M/m L/l H/h V/v C/c S/s Z/z.
/// Cubic Béziers (C/S) cover both outlines; the `S` smooth-cubic reflection of
/// the previous control point is handled per the SVG spec.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var i = d.startIndex
        let end = d.endIndex

        var current = CGPoint.zero      // current point
        var start = CGPoint.zero        // subpath start (for Z)
        var lastCtrl: CGPoint? = nil    // previous cubic control (for S/s)
        var lastCmd: Character = " "

        func skipSeparators() {
            while i < end {
                let c = d[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                    i = d.index(after: i)
                } else { break }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            guard i < end else { return nil }
            var s = ""
            // optional sign
            if d[i] == "-" || d[i] == "+" { s.append(d[i]); i = d.index(after: i) }
            var seenDot = false
            var seenExp = false
            while i < end {
                let c = d[i]
                if c.isNumber {
                    s.append(c); i = d.index(after: i)
                } else if c == "." && !seenDot && !seenExp {
                    seenDot = true; s.append(c); i = d.index(after: i)
                } else if (c == "e" || c == "E") && !seenExp {
                    seenExp = true; s.append(c); i = d.index(after: i)
                    if i < end && (d[i] == "-" || d[i] == "+") { s.append(d[i]); i = d.index(after: i) }
                } else {
                    break
                }
            }
            return Double(s).map { CGFloat($0) }
        }

        func isCommand(_ c: Character) -> Bool {
            "MmLlHhVvCcSsZzAaQqTt".contains(c)
        }

        while i < end {
            skipSeparators()
            guard i < end else { break }
            var cmd = d[i]
            if isCommand(cmd) {
                i = d.index(after: i)
            } else {
                // Implicit repeat of the previous command (SVG spec): after an
                // M the implicit command is L; otherwise repeat lastCmd.
                cmd = lastCmd == "M" ? "L" : (lastCmd == "m" ? "l" : lastCmd)
            }

            switch cmd {
            case "M", "m":
                guard let x = readNumber(), let y = readNumber() else { break }
                let p = cmd == "m" ? CGPoint(x: current.x + x, y: current.y + y)
                                   : CGPoint(x: x, y: y)
                path.move(to: p)
                current = p; start = p; lastCtrl = nil
            case "L", "l":
                guard let x = readNumber(), let y = readNumber() else { break }
                let p = cmd == "l" ? CGPoint(x: current.x + x, y: current.y + y)
                                   : CGPoint(x: x, y: y)
                path.addLine(to: p)
                current = p; lastCtrl = nil
            case "H", "h":
                guard let x = readNumber() else { break }
                let nx = cmd == "h" ? current.x + x : x
                let p = CGPoint(x: nx, y: current.y)
                path.addLine(to: p)
                current = p; lastCtrl = nil
            case "V", "v":
                guard let y = readNumber() else { break }
                let ny = cmd == "v" ? current.y + y : y
                let p = CGPoint(x: current.x, y: ny)
                path.addLine(to: p)
                current = p; lastCtrl = nil
            case "C", "c":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let rel = cmd == "c"
                let c1 = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let p  = rel ? CGPoint(x: current.x + x,  y: current.y + y)  : CGPoint(x: x, y: y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastCtrl = c2
            case "S", "s":
                guard let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let rel = cmd == "s"
                // Reflect the previous cubic control point about the current
                // point; if the prior command was not a cubic, the reflection
                // is the current point itself.
                let reflected: CGPoint
                if let lc = lastCtrl, lastCmd == "C" || lastCmd == "c" || lastCmd == "S" || lastCmd == "s" {
                    reflected = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else {
                    reflected = current
                }
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let p  = rel ? CGPoint(x: current.x + x,  y: current.y + y)  : CGPoint(x: x, y: y)
                path.addCurve(to: p, control1: reflected, control2: c2)
                current = p; lastCtrl = c2
            case "Z", "z":
                path.closeSubpath()
                current = start; lastCtrl = nil
            default:
                // Unsupported command — bail to avoid an infinite loop.
                return path
            }
            lastCmd = cmd
        }
        return path
    }
}

#if DEBUG
struct BridgeServiceMarks_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            NotionMark().frame(width: 40, height: 40)
            StripeMark().frame(width: 40, height: 40)
        }
        .padding(40)
        .background(BridgeTokens.bgCanvas)
    }
}
#endif
