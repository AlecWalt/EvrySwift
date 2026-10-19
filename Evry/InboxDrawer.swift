//
//  InboxDrawer.swift
//  Evry
//
//  Live drag state for the Inbox: the page offset for swiping between
//  Schedule and Tasks, and the pull that opens the month view.
//

import SwiftUI

/// The live finger offset while swiping between Schedule and Tasks — in its
/// own observable so drag frames only move the pages, not re-render the Inbox.
@Observable
final class InboxPageDrag {
    var x: CGFloat = 0
}

struct PageDragOffset: ViewModifier {
    let base: CGFloat
    let drag: InboxPageDrag

    func body(content: Content) -> some View {
        content.offset(x: base + drag.x)
    }
}

/// How far the week strip has been pulled down towards the month view — its
/// own observable, so drag frames only fade the pages.
@Observable
final class InboxMonthPull {
    var y: CGFloat = 0
}

/// Fades (and gently sinks) the Inbox's pages as the month view is pulled
/// open, and keeps them hidden while it's open.
struct MonthPullFade: ViewModifier {
    let pull: InboxMonthPull
    let open: Bool

    func body(content: Content) -> some View {
        let f = open ? 1 : min(max(pull.y, 0) / 160, 1)
        content
            .opacity(1 - f)
            .offset(y: open ? 24 : pull.y * 0.25)
    }
}
