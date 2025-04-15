import SwiftUI

struct EventsTabView: View {
    var body: some View {
        TabView {
            EventFeedView()
                .tabItem {
                    Label("Feed", systemImage: "list.bullet.rectangle")
                }

            MyEventsView()
                .tabItem {
                    Label("My Events", systemImage: "person.crop.circle")
                }

            CreateEventView()
                .tabItem {
                    Label("Create", systemImage: "plus.circle")
                }
        }
        .accentColor(.blue)
    }
}
