import SwiftUI

// Every tile that names a vendor carries the vendor's real mark (`Assets.xcassets/Brands`, with
// `SOURCES.md` beside them) in its official color, at one size and radius per context (round 3,
// CHANGES.md §1): 34 pt / r9 in lists, 40 pt / r10 in the Privacy diagram, 52 pt / r13 as a
// screen's header. Two pairs share a mark, so the tile color tells them apart: ChatGPT is white
// on black and Codex black on white; Claude is on white and Claude Code on Anthropic's near-black.

/// Who a tile stands for.
enum BrandMark: Hashable {
    case chatgpt, openai, codex, claude, claudeCode, cursor, gemini, meta, icloud, soniox
    /// A provider with no mark of its own here (Apple Private Cloud Compute): a neutral tile.
    case glyph(String)
    /// An assistant this app has no mark for: its initials in a neutral tile.
    case initials(String)

    /// The transcription and AI providers by the names the app gives them.
    static func forProvider(named name: String) -> BrandMark {
        switch name.lowercased() {
        case "soniox": return .soniox
        case "openai": return .openai
        case let other where other.contains("apple"): return .glyph("apple.logo")
        default: return initials(of: name)
        }
    }

    /// An assistant by the name the server's access list gives it ("ChatGPT", "Claude",
    /// "Codex on Mac", "Claude Code", …). Claude Code is checked before Claude.
    static func forAssistant(named name: String) -> BrandMark {
        let lower = name.lowercased()
        if lower.contains("chatgpt") { return .chatgpt }
        if lower.contains("claude code") || lower.contains("claude-code") { return .claudeCode }
        if lower.contains("codex") { return .codex }
        if lower.contains("claude") { return .claude }
        if lower.contains("cursor") { return .cursor }
        if lower.contains("gemini") { return .gemini }
        if lower.contains("openai") { return .openai }
        return initials(of: name)
    }

    /// The company or product that keeps what the assistant read: "Codex on Mac" is Codex.
    static func vendorName(ofAssistant name: String) -> String {
        guard let range = name.range(of: " on ", options: .backwards), range.lowerBound > name.startIndex
        else { return name }
        return String(name[..<range.lowerBound])
    }

    static func initials(of name: String) -> BrandMark {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return .initials(letters.isEmpty ? "?" : letters.uppercased())
    }

    var assetName: String? {
        switch self {
        case .chatgpt, .openai, .codex: return "BrandOpenAI"
        case .claude, .claudeCode: return "BrandClaude"
        case .cursor: return "BrandCursor"
        case .gemini: return "BrandGemini"
        case .meta: return "BrandMeta"
        case .icloud: return "BrandICloud"
        case .soniox: return "BrandSoniox"
        case .glyph, .initials: return nil
        }
    }

    var markColor: Color {
        switch self {
        case .chatgpt: return Tokens.Brand.white
        case .openai, .codex, .cursor: return Tokens.Brand.black
        case .claude, .claudeCode: return Tokens.Brand.claude
        case .gemini: return Tokens.Brand.gemini
        case .meta: return Tokens.Brand.meta
        case .icloud: return Tokens.Brand.iCloud
        case .soniox: return .clear
        case .glyph, .initials: return Tokens.secondaryBody
        }
    }

    var tileColor: Color {
        switch self {
        case .chatgpt: return Tokens.Brand.black
        case .claudeCode: return Tokens.Brand.anthropicInk
        case .glyph, .initials: return Tokens.grayChipFill
        default: return Tokens.Brand.white
        }
    }

    var isDarkTile: Bool { self == .chatgpt || self == .claudeCode }
    /// Soniox's own icon is the whole square.
    var fillsTile: Bool { self == .soniox }
    /// Meta's mark is wide, so it is drawn a little larger to read at the same weight.
    var markScale: CGFloat { self == .meta ? 0.66 : 0.58 }
}

/// The three tile sizes.
enum TileSize {
    case list, diagram, header

    var side: CGFloat {
        switch self {
        case .list: return 34
        case .diagram: return 40
        case .header: return 52
        }
    }

    var radius: CGFloat {
        switch self {
        case .list: return 9
        case .diagram: return 10
        case .header: return 13
        }
    }
}

/// A vendor's mark in its tile.
struct BrandTile: View {
    let mark: BrandMark
    var size: TileSize = .list

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        ZStack {
            shape.fill(mark.tileColor)
            content
        }
        .frame(width: size.side, height: size.side)
        .clipShape(shape)
        .overlay {
            switch mark {
            case .glyph, .initials:
                shape.strokeBorder(Tokens.cardBorder, lineWidth: 0.5)
            default:
                shape.strokeBorder(mark.isDarkTile ? Tokens.Brand.edgeOnDark : Tokens.Brand.edgeOnWhite, lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let asset = mark.assetName {
            if mark.fillsTile {
                Image(asset).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(mark.markColor)
                    .frame(width: size.side * mark.markScale, height: size.side * mark.markScale)
            }
        } else if case .glyph(let name) = mark {
            Image(systemName: name)
                .font(.system(size: size.side * 0.5, weight: .medium))
                .foregroundStyle(Tokens.secondaryBody)
        } else if case .initials(let letters) = mark {
            Text(letters)
                .font(.system(size: size.side * (letters.count > 2 ? 0.34 : 0.38), weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.secondaryBody)
        }
    }
}

/// One of the app's own glyphs in a tile: the server, this iPhone, a plus.
struct GlyphTile: View {
    enum Style { case own, good, neutral }

    let systemName: String
    var style: Style = .own
    var size: TileSize = .list

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size == .list ? 17 : (size == .diagram ? 20 : 26), weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: size.side, height: size.side)
            .background(shape.fill(background))
            .overlay {
                if style == .neutral { shape.strokeBorder(Tokens.cardBorder, lineWidth: 0.5) }
            }
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch style {
        case .own: return Tokens.tint
        case .good: return Tokens.good
        case .neutral: return Tokens.tertiary
        }
    }

    private var background: Color {
        switch style {
        case .own: return Tokens.tintFill12
        case .good: return Tokens.goodFill
        case .neutral: return Tokens.grayChipFill
        }
    }
}

/// A row that stands for several apps: their marks, small, inside one list tile, like an iOS
/// folder. `more` adds a small plus: "and others".
struct FolderTile: View {
    let marks: [BrandMark]
    var more = false

    var body: some View {
        let cells: [BrandMark?] = marks + (more ? [nil] : [])
        let shape = RoundedRectangle(cornerRadius: TileSize.list.radius, style: .continuous)
        VStack(spacing: 1.5) {
            HStack(spacing: 1.5) {
                ForEach(Array(cells.prefix(2).enumerated()), id: \.offset) { _, cell in mini(cell) }
            }
            if cells.count > 2 {
                HStack(spacing: 1.5) {
                    ForEach(Array(cells.dropFirst(2).enumerated()), id: \.offset) { _, cell in mini(cell) }
                }
            }
        }
        .frame(width: TileSize.list.side, height: TileSize.list.side)
        .background(shape.fill(Tokens.grayChipFill))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mini(_ mark: BrandMark?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if let mark, let asset = mark.assetName {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(mark.markColor)
                .frame(width: 10.5, height: 10.5)
                .frame(width: 15, height: 15)
                .background(shape.fill(mark.tileColor))
                .overlay(shape.strokeBorder(mark.isDarkTile ? Color.clear : Tokens.Brand.edgeOnWhite, lineWidth: 0.5))
        } else {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Tokens.tertiary)
                .frame(width: 15, height: 15)
                .overlay(shape.strokeBorder(Tokens.chevron, lineWidth: 1))
        }
    }
}

/// Overlapping marks, each keeping a ring of the surface it sits on.
struct TileStack: View {
    let marks: [BrandMark]
    var size: TileSize = .diagram

    var body: some View {
        HStack(spacing: size == .diagram ? -6 : -10) {
            ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                BrandTile(mark: mark, size: size)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: size.radius + 2, style: .continuous)
                            .fill(Tokens.surface))
                    .zIndex(Double(index))
            }
        }
        .padding(-2)
        .accessibilityHidden(true)
    }
}

/// "Assistants · None yet": a hatched tile where they would hang.
struct HollowTile: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TileSize.diagram.radius, style: .continuous)
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6 * 1.414
            }
            context.stroke(path, with: .color(Tokens.track), lineWidth: 1)
        }
        .frame(width: TileSize.diagram.side, height: TileSize.diagram.side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Tokens.chevron, lineWidth: 1.5))
        .accessibilityHidden(true)
    }
}

#Preview("Brand tiles") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            ForEach([BrandMark.chatgpt, .claude, .codex, .claudeCode, .cursor, .gemini], id: \.self) {
                BrandTile(mark: $0)
            }
        }
        HStack {
            ForEach([BrandMark.soniox, .openai, .meta, .icloud, .glyph("apple.logo"), .initials("PA")], id: \.self) {
                BrandTile(mark: $0, size: .diagram)
            }
        }
        HStack {
            FolderTile(marks: [.codex, .claudeCode, .cursor])
            FolderTile(marks: [.gemini], more: true)
            TileStack(marks: [.chatgpt, .claude, .codex])
            HollowTile()
            BrandTile(mark: .chatgpt, size: .header)
        }
    }
    .padding()
    .background(Tokens.surface)
}
