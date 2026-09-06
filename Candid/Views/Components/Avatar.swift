import SwiftUI

/// A person's monogram — their username's first letter on a tinted circle.
/// The design never shows an actual photo here; Feed had no avatar at all
/// before this pass (`FeedPostRow` was username text only).
struct Avatar: View {
    let username: String
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(Color.candidAvatarBG)
            .frame(width: size, height: size)
            .overlay(
                Text(username.prefix(1).lowercased())
                    .font(.newsreader(size * 0.5))
                    .foregroundStyle(.candidAvatarText)
            )
    }
}

#Preview {
    HStack(spacing: 16) {
        Avatar(username: "nadia")
        Avatar(username: "maren", size: 56)
    }
    .padding()
    .background(Color.candidGround)
}
