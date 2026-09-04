import SwiftUI

/// Shown instead of `RootView` when `SupabaseService` can't build a client —
/// a missing or malformed `Config/Secrets.xcconfig`, most likely. Centralizing
/// this here means no service call anywhere else needs to handle that case;
/// `error.localizedDescription` already explains exactly what to fix, via
/// `SupabaseConfigurationError`.
struct ConfigurationErrorView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Configuration Error")
                .font(.title2)

            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ConfigurationErrorView(error: SupabaseConfigurationError.missingValue(key: "SUPABASE_API_HOST"))
}
