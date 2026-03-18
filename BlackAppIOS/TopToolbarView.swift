import SwiftUI

struct TopToolbarView: View {
    var onLogoTap: () -> Void
    var onSearchTap: () -> Void
    var adminButton: AnyView? = nil

    // BlackAppMoney action (optional, non-breaking)
    var onMoneyTap: (() -> Void)? = nil

    @State private var showSupportModal = false
    @State private var moneyRotation: Double = 0

    var body: some View {
        ZStack {
            HStack(spacing: 14) {

                // ✅ BlackAppMoney button (LEFT)
                Button {
                    triggerMoneySpin()
                    onMoneyTap?()
                } label: {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white) // change to .white if desired
                        .rotationEffect(.degrees(moneyRotation))
                        .animation(
                            .interpolatingSpring(stiffness: 120, damping: 14),
                            value: moneyRotation
                        )
                        .accessibilityLabel("BlackAppMoney")
                }
                .buttonStyle(.plain)
#if os(macOS)
                .onHover { hovering in
                    if hovering {
                        triggerMoneySpin()
                    }
                }
#endif

                // Search button — unchanged
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .font(.title2)
                }

                Spacer()

                // Support button — unchanged
                Button(action: {
                    showSupportModal = true
                }) {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.white)
                        .font(.title2)
                        .padding(.trailing, 4)
                }

                // Admin button — unchanged
                if let adminButton = adminButton {
                    adminButton
                        .frame(width: 40, height: 40)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal)

            // Center logo — unchanged
            Button(action: onLogoTap) {
                Image("blackapp_logo")
                    .resizable()
                    .frame(width: 40, height: 40)
            }
        }
        .frame(height: 50)
        .background(Color.black)
        .sheet(isPresented: $showSupportModal) {
            SupportModalView()
        }
    }

    // MARK: - Subtle spin logic (left → right circular motion)
    private func triggerMoneySpin() {
        moneyRotation += 360
    }
}
