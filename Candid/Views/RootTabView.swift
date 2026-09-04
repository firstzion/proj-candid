import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "photo.stack")
                }

            PostView()
                .tabItem {
                    Label("Post", systemImage: "plus.square")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(SessionStore(client: .preview))
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
}
