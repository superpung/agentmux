import SwiftUI

/// A sidebar row: the title above the details on the left, and on the right
/// the time in the top corner and the status mark in the bottom corner, as
/// Mail sets a message's date at its top right. The right column is pinned
/// to the row's top and bottom edges, so the time sits as close to the top
/// as the mark does to the bottom, and both line up down the list against
/// the trailing edge; a row without a mark has nothing there.
struct TwoLineRow<Title: View, Detail: View, Time: View, Status: View>: View {
    private let title: Title
    private let detail: Detail
    private let time: Time
    private let status: Status

    init(@ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail,
         @ViewBuilder time: () -> Time, @ViewBuilder status: () -> Status) {
        self.title = title()
        self.detail = detail()
        self.time = time()
        self.status = status()
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                title.lineLimit(1)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                time
                Spacer(minLength: 0)
                status
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
