import SwiftUI

struct FeedView: View {
    @State private var feedState: FeedState = .loading

    private enum FeedState {
        case loading
        case loaded([FeedPost])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch feedState {
                case .loading:
                    ProgressView()

                case .loaded(let posts) where posts.isEmpty:
                    ContentUnavailableView("No Posts Yet", systemImage: "photo.on.rectangle.angled")

                case .loaded(let posts):
                    List(posts) { post in
                        PostRow(post: post)
                    }
                    .listStyle(.plain)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Feed")
            .task { await load() }
        }
    }

    private func load() async {
        feedState = .loading
        do {
            feedState = .loaded(try await FeedService().fetchPosts())
        } catch {
            feedState = .failed(error.localizedDescription)
        }
    }
}

private struct PostRow: View {
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.username)
                .font(.headline)

            AsyncImage(url: post.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                @unknown default:
                    EmptyView()
                }
            }

            if let caption = post.caption {
                Text(caption)
            }

            Text(post.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    FeedView()
}
