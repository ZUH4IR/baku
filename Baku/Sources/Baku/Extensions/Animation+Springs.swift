import SwiftUI

extension Animation {
    /// Snappy spring for opening the notch
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.8)

    /// Smooth spring for closing the notch
    static let notchClose = Animation.spring(response: 0.45, dampingFraction: 1.0)

    /// Quick animation for hover effects
    static let hover = Animation.easeInOut(duration: 0.15)

    /// Standard interactive spring
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8)
}

extension View {
    /// Apply hover effect to a view
    func hoverEffect(isHovered: Bool) -> some View {
        self
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.hover, value: isHovered)
    }

    /// Conditional modifier
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
