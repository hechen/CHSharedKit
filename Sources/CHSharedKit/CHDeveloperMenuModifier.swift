import SwiftUI

public struct CHDeveloperMenu<Item: View>: ViewModifier {
    @Binding var tapCount: Int
    @Binding var visible: Bool
    let threshold: Int
    let menuContent: () -> Item

    public init(tapCount: Binding<Int>, visible: Binding<Bool>, threshold: Int = 5, @ViewBuilder menuContent: @escaping () -> Item) {
        self._tapCount = tapCount
        self._visible = visible
        self.threshold = threshold
        self.menuContent = menuContent
    }

    public func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    tapCount += 1
                    if tapCount >= threshold { withAnimation { visible = true } }
                }

            if visible {
                menuContent()
            }
        }
    }
}

public extension View {
    func chDeveloperMenu<Item: View>(
        tapCount: Binding<Int>,
        visible: Binding<Bool>,
        threshold: Int = 5,
        @ViewBuilder menuContent: @escaping () -> Item
    ) -> some View {
        modifier(CHDeveloperMenu(tapCount: tapCount, visible: visible, threshold: threshold, menuContent: menuContent))
    }
}
