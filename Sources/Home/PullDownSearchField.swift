import SwiftUI

/// 下拉唤出的搜索框。不常驻——不搜的时候它根本不占位置。
struct PullDownSearchField: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                TextField("搜索站点", text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.search)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: Capsule())

            Button("取消") {
                text = ""
                focused = false
                onCancel()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
