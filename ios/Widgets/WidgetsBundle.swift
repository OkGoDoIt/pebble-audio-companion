import SwiftUI
import WidgetKit

/// The extension's entry point.
///
/// Order matters: the gallery lists them in this order, and the first one is what most people
/// will add. "Recording status" leads because it is the only one that both answers the product's
/// core question and lets the user act on the answer; "Day coverage" is last because it is a
/// diagnostic, not a headline.
@main
struct CompanionWidgets: WidgetBundle {
    var body: some Widget {
        CaptureStatusWidget()
        NowWidget()
        FollowUpsWidget()
        CoverageWidget()
        CaptureControl()
    }
}
