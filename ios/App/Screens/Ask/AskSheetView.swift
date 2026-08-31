import SwiftUI

/// The Ask sheet (owner: Library/Conversation UI agent). Presented from all three entry
/// points with a context scope (plan 2-C).
struct AskSheetView: View {
    let route: Route

    var body: some View {
        Text(Copy.Ask.title)
    }
}
