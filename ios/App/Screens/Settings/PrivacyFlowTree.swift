import SwiftUI

/// The Privacy stance's flow (round 3, CHANGES.md §2): This iPhone at the root, one branch per
/// place the phone sends to in the model's order, and the assistants hanging off the server.
/// Vertical, each level 50 pt further in, so no row grows long at 390 pt and every label wraps
/// at accessibility sizes instead of running off the card. The geometry is the mockup's: 40 pt
/// tiles, a 2 pt line under the root tile's center, a 22 pt stub and a 6 × 10 arrowhead into
/// each tile's middle. A paused server's branch is dashed with no arrowhead and says so; the
/// assistants under it stay solid, because they can still read what the server has.
struct PrivacyFlowTree: View {
    let presentation: PrivacyPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                GlyphTile(systemName: "iphone", style: .good, size: .diagram)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Copy.Settings.Privacy.thisIPhone).font(AssistantFont.flowName).foregroundStyle(Tokens.label)
                    Text(Copy.Settings.Privacy.audioAndText).font(AssistantFont.flowSub).foregroundStyle(Tokens.tertiary)
                }
                .padding(.top, 4)
            }
            FlowBranches(count: presentation.destinations.count) { index in
                destinationNode(presentation.destinations[index])
            } dashed: { index in
                presentation.destinations[index].paused
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Settings.Privacy.flowAccessibility)
        .accessibilityValue(spoken)
    }

    @ViewBuilder
    private func destinationNode(_ destination: PrivacyDestination) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                destinationTile(destination, size: .diagram)
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(AssistantFont.flowName)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if destination.paused {
                        Text(destination.why)
                            .font(AssistantFont.flowSub)
                            .foregroundStyle(Tokens.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !destination.chips.isEmpty {
                        ChipFlow(spacing: 4) {
                            ForEach(destination.chips, id: \.self) { AssistantChip(chip: $0, small: true) }
                        }
                        .padding(.top, 1)
                    }
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if destination.kind == .server {
                assistantBranches
            }
        }
    }

    /// Under the server: each group of assistants with what it may do, or the hatched tile.
    @ViewBuilder
    private var assistantBranches: some View {
        let groups = presentation.assistantGroups
        if groups.isEmpty {
            FlowBranches(count: 1) { _ in
                HStack(alignment: .top, spacing: 10) {
                    HollowTile()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Copy.Settings.Privacy.assistants).font(AssistantFont.flowName).foregroundStyle(Tokens.tertiary)
                        Text(Copy.Settings.Privacy.noneYet).font(AssistantFont.flowSub).foregroundStyle(Tokens.tertiary)
                    }
                    .padding(.top, 1)
                }
            } dashed: { _ in true }
        } else {
            FlowBranches(count: groups.count) { index in
                let group = groups[index]
                VStack(alignment: .leading, spacing: 6) {
                    TileStack(marks: group.marks, size: .diagram)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Copy.list(group.names))
                            .font(AssistantFont.flowName)
                            .foregroundStyle(Tokens.label)
                            .fixedSize(horizontal: false, vertical: true)
                        ChipFlow(spacing: 4) { AssistantChip(chip: group.chip, small: true) }
                            .padding(.top, 1)
                    }
                }
            } dashed: { _ in false }
        }
    }

    /// What VoiceOver reads for the whole tree.
    private var spoken: String {
        var parts: [String] = []
        for destination in presentation.destinations {
            let what = destination.paused ? destination.why : destination.chips.map(\.label).joined(separator: ", ")
            parts.append("\(destination.name): \(what)")
            if destination.kind == .server {
                for group in presentation.assistantGroups {
                    parts.append("\(Copy.list(group.names)): \(group.chip.label)")
                }
            }
        }
        return parts.joined(separator: ". ")
    }
}

/// One level of branches: a trunk 19 pt in (under the parent tile's center), each child 30 pt
/// further in with 12 pt above it, joined by a stub and an arrowhead.
struct FlowBranches<Node: View>: View {
    let count: Int
    @ViewBuilder let node: (Int) -> Node
    let dashed: (Int) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                node(index)
                    .padding(.leading, 30)
                    .padding(.top, 12)
                    .background(alignment: .topLeading) {
                        let isLast = index == count - 1
                        let off = dashed(index)
                        // The trunk is dashed only where it ends in an off branch.
                        FlowTrunk(isLast: isLast)
                            .stroke(off && isLast ? Tokens.chevron : Tokens.tint, style: style(off && isLast))
                        FlowStub(dashed: off)
                            .stroke(off ? Tokens.chevron : Tokens.tint, style: style(off))
                        if !off {
                            FlowArrowhead().fill(Tokens.tint)
                        }
                    }
            }
        }
        .padding(.leading, 19)
    }

    private func style(_ dashed: Bool) -> StrokeStyle {
        dashed ? StrokeStyle(lineWidth: 2, dash: [5, 4]) : StrokeStyle(lineWidth: 2)
    }
}

/// The trunk's segment beside one child: its whole height, or down to the stub for the last.
struct FlowTrunk: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 0))
        path.addLine(to: CGPoint(x: 1, y: isLast ? 33 : rect.height))
        return path
    }
}

/// The stub, at the tile's middle (12 pt above the tile, 20 pt into it). A dashed one runs all
/// the way to the tile; a solid one stops at the arrowhead.
struct FlowStub: Shape {
    let dashed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 32))
        path.addLine(to: CGPoint(x: dashed ? 28 : 22, y: 32))
        return path
    }
}

/// The 6 × 10 arrowhead that ends a solid stub, just short of the tile.
struct FlowArrowhead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 21, y: 27))
        path.addLine(to: CGPoint(x: 27, y: 32))
        path.addLine(to: CGPoint(x: 21, y: 37))
        path.closeSubpath()
        return path
    }
}
