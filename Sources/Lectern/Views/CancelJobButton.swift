import SwiftUI

struct CancelJobButton: View {
    var isCancelling = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isCancelling ? "Cancelling…" : "Cancel")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minWidth: 74, minHeight: 30)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isCancelling)
        .opacity(isCancelling ? 0.6 : 1)
        .accessibilityLabel("Cancel job")
    }
}
