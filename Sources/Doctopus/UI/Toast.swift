import SwiftUI
import AppKit

/// A short message about something that just finished — an analysis run, a
/// batch rename, an import. Shown as a toast that goes away by itself, so a
/// routine result never takes a click to get rid of. Things that went wrong
/// still go through `AppModel.errorMessage`, which is an alert.
struct Notice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The thing asked for happened.
        case success
        /// Nothing needed doing, or there is nothing to say beyond a fact.
        case info
        /// It happened, but not entirely — some items failed or were skipped.
        case warning

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return .green
            case .info: return .secondary
            case .warning: return .orange
            }
        }

        /// A warning is worth a little longer to read.
        var duration: Duration { self == .warning ? .seconds(6) : .seconds(4) }
    }

    let id = UUID()
    var text: String
    var kind: Kind = .success
}

/// The toast itself: an icon and a line or two of text on a material card.
/// Clicking it dismisses it early.
struct NoticeToast: View {
    let notice: Notice
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.kind.icon)
                .foregroundStyle(notice.kind.tint)
            Text(notice.text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .frame(maxWidth: 440)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onDismiss)
        .help("Click to dismiss")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// A modifier rather than a plain function so `model.notice` is read inside a
/// `body`, where observation tracks it — whatever view it is attached to.
private struct NoticeOverlay: ViewModifier {
    let model: AppModel
    let bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    NoticeToast(notice: notice) { model.dismissNotice() }
                        .padding(.horizontal, 20)
                        .padding(.bottom, bottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(notice.id)
                }
            }
            .animation(.spring(duration: 0.35), value: model.notice)
    }
}

extension View {
    /// Floats the model's current notice over the bottom of this view. Applied
    /// to the main window's centre pane and to the Settings window, since an
    /// analysis started from Settings finishes while Settings is in front.
    func noticeOverlay(_ model: AppModel, bottomPadding: CGFloat = 16) -> some View {
        modifier(NoticeOverlay(model: model, bottomPadding: bottomPadding))
    }
}
