import SwiftUI

struct TopToolbarView: View {
    var onLogoTap: () -> Void
    var onSearchTap: () -> Void
    var adminButton: AnyView? = nil

    @State private var showSupportModal = false

    var body: some View {
        ZStack {
            HStack {
                // Search button (left)
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .font(.title2)
                }

                Spacer()

                // Support button (right)
                Button(action: {
                    showSupportModal = true
                }) {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.white)
                        .font(.title2)
                        .padding(.trailing, 4)
                }

                // Admin button if available
                if let adminButton = adminButton {
                    adminButton
                        .frame(width: 40, height: 40)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal)

            // Center logo
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
}
