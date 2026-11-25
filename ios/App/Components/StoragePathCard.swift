import SwiftUI

/// The life of a recording as three stops on one line: this phone, iCloud, deleted. The line is
/// the color of where the audio is (the same two colors the bars use), and dashed where nothing
/// travels. The two later stops open their own screen.
struct StoragePathCard<CloudDestination: View, DeleteDestination: View>: View {
    let path: StoragePath
    @ViewBuilder var cloudDestination: CloudDestination
    @ViewBuilder var deleteDestination: DeleteDestination

    private typealias C = Copy.Settings.Storage

    var body: some View {
        VStack(spacing: 0) {
            StopRow(
                tile: .init(symbol: "iphone", fill: Tokens.tint, ink: Tokens.onTint, isUsed: true),
                rail: path.toCloud, name: C.phoneStop, size: path.phoneSize
            ) {
                Text(path.phoneLine)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                if let room = path.room {
                    StorageBar(
                        parts: [.init(id: "used", bytes: min(room.used, room.limit), color: Tokens.tint)],
                        total: room.limit, height: 6)
                        .padding(.top, 5)
                }
            }
            NavigationLink { cloudDestination } label: {
                stop(
                    path.cloud, name: C.cloudStop,
                    tile: .init(
                        symbol: "icloud", fill: Tokens.captured, ink: Tokens.capturedInk,
                        isUsed: path.cloud.isUsed),
                    rail: path.toDeleted)
            }
            .buttonStyle(.plain)
            NavigationLink { deleteDestination } label: {
                stop(
                    path.deleted, name: C.deletedStop,
                    tile: .init(
                        symbol: "trash", fill: Tokens.destructiveFill, ink: Tokens.destructiveInk,
                        isUsed: path.deleted.isUsed),
                    rail: nil)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }

    private func stop(
        _ stop: StoragePath.Stop, name: String, tile: StopTile, rail: StoragePath.Rail?
    ) -> some View {
        StopRow(
            tile: tile, rail: rail, name: name, nameColor: stop.isUsed ? Tokens.label : Tokens.tertiary,
            size: stop.size, showsChevron: true
        ) {
            Text(stop.when)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.tint)
                .fixedSize(horizontal: false, vertical: true)
            if let note = stop.note {
                Text(note.text)
                    .font(AppFont.footnote)
                    .foregroundStyle(note.needsAttention ? Tokens.attention : Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A 40 pt tile on the line: filled while audio reaches it, a dashed outline while none does.
private struct StopTile: View {
    let symbol: String
    let fill: Color
    let ink: Color
    let isUsed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TileSize.diagram.radius, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isUsed ? ink : Tokens.meta)
            .frame(width: TileSize.diagram.side, height: TileSize.diagram.side)
            .background(shape.fill(isUsed ? fill : Tokens.surface))
            .overlay {
                if !isUsed {
                    shape.strokeBorder(Tokens.chevron, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
            .accessibilityHidden(true)
    }
}

/// One stop: its tile and the line below it, its name and what is true of it, and its size.
private struct StopRow<Detail: View>: View {
    let tile: StopTile
    /// What travels on to the next stop; nil at the last one.
    let rail: StoragePath.Rail?
    let name: String
    var nameColor: Color = Tokens.label
    let size: String?
    var showsChevron = false
    @ViewBuilder var detail: Detail

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 0) {
                let head = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
                head {
                    Text(name)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(nameColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let size {
                        Text(size)
                            .font(AppFont.rowTitle.monospacedDigit())
                            .foregroundStyle(Tokens.label)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, rail == nil ? 0 : 18)
            // The chevron's slot is kept on every row, so the sizes line up down the card.
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.chevron)
                .padding(.top, 3)
                .opacity(showsChevron ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(minHeight: rail == nil ? 44 : 66, alignment: .top)
        .background(alignment: .topLeading) {
            if let rail {
                RailLine()
                    .stroke(
                        color(rail),
                        style: StrokeStyle(lineWidth: 4, dash: rail == .nothing ? [5, 4] : []))
                    .frame(width: TileSize.diagram.side)
                    .padding(.top, TileSize.diagram.side)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func color(_ rail: StoragePath.Rail) -> Color {
        switch rail {
        case .phone: return Tokens.tint
        case .cloud: return Tokens.captured
        case .nothing: return Tokens.chevron
        }
    }
}

private struct RailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
