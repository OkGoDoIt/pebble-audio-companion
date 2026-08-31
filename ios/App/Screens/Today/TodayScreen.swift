import SwiftUI

/// Today tab root (built out in the M4/M6 UI wave — owner: Today/Live UI agent).
struct TodayScreen: View {
    var body: some View {
        List {
            NavigationLink("Design token gallery") { TokenGallery() }
            NavigationLink("Component gallery") { ComponentGallery() }
        }
        .navigationTitle(Copy.Today.title)
    }
}
