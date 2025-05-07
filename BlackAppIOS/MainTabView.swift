import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            GossipTabView()
                .tabItem {
                    Label("Gossip", systemImage: "quote.bubble")
                }

            EventsTabView()
                .tabItem {
                    Label("Events", systemImage: "calendar")
                }

            ExploreTabView()
                .tabItem {
                    Image(systemName: "globe")
                    Text("Explore")
                }
            
            ChatTabView()
                .tabItem {
                    Label("Chat", systemImage: "message")
                }

            ProfileTabView()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("Profile")
                }
        }
        .accentColor(.blue)
    }
}
