import SwiftUI

/// A row of pill options, filled with the accent when selected. The shared
/// look behind Post's visibility control and Profile's appearance switcher —
/// Candid Design's capsule vocabulary ("Choose another", the primary button)
/// rather than a native segmented control's chrome.
struct CapsuleToggle<Option: Hashable & CaseIterable>: View where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Option.allCases), id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.candidGround : Color.candidInk)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background {
                            Capsule().fill(isSelected ? Color.candidAccent : Color.clear)
                        }
                        .overlay {
                            Capsule().strokeBorder(Color.candidBorder.opacity(isSelected ? 0 : 0.6))
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
