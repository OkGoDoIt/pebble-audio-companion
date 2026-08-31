import SwiftUI
import WidgetKit

/// The extension's entry point: the Today-coverage widget (Home + Lock Screen) and the
/// Control Center capture toggle.
@main
struct CompanionWidgets: WidgetBundle {
    var body: some Widget {
        CoverageWidget()
        CaptureControl()
    }
}
