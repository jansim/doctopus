import SwiftUI
import AppKit

struct Notice: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case info
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

        var duration: Duration { self == .warning ? .seconds(6) : .seconds(4) }
    }

    let id = UUID()
    var text: String
    var kind: Kind = .success
}

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
    func noticeOverlay(_ model: AppModel, bottomPadding: CGFloat = 16) -> some View {
        modifier(NoticeOverlay(model: model, bottomPadding: bottomPadding))
    }
}
