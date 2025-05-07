import SwiftUI

struct TopToolbarView: View {
    var onLogoTap: () -> Void
    var onSearchTap: () -> Void
    var adminButton: AnyView? = nil

    var body: some View {
        ZStack {
            HStack {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .font(.title2)
                }
                Spacer()
                if let adminButton = adminButton {
                    adminButton
                        .frame(width: 40, height: 40)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal)

            Button(action: onLogoTap) {
                Image("blackapp_logo")
                    .resizable()
                    .frame(width: 40, height: 40)
            }
        }
        .frame(height: 50)
        .background(Color.black)
    }
}
