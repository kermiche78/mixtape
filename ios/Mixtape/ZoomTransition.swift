import SwiftUI

// Animation « zoom » façon Apple Music : la pochette touchée grandit
// jusqu'à devenir la page de l'album (iOS 18 et plus).

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Espace partagé entre les pochettes et les pages d'album.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Pochette de départ de l'animation.
    func zoomSource(id: String) -> some View {
        modifier(ZoomSourceModifier(id: id))
    }

    /// Page qui s'ouvre en zoomant depuis la pochette.
    func zoomDestination(id: String) -> some View {
        modifier(ZoomDestinationModifier(id: id))
    }
}

private struct ZoomSourceModifier: ViewModifier {
    @Environment(\.zoomNamespace) private var namespace
    let id: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            if #available(iOS 18.0, *) {
                content.matchedTransitionSource(id: id, in: namespace)
            } else {
                content
            }
        } else {
            content
        }
    }
}

private struct ZoomDestinationModifier: ViewModifier {
    @Environment(\.zoomNamespace) private var namespace
    let id: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            if #available(iOS 18.0, *) {
                content.navigationTransition(.zoom(sourceID: id, in: namespace))
            } else {
                content
            }
        } else {
            content
        }
    }
}
