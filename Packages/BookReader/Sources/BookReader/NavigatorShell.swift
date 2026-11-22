import SwiftUI
import UIKit

/// The Readium navigator as a SwiftUI view: a container that carries the
/// UIViewController as a child and lays it over the whole area.
struct NavigatorShell: UIViewControllerRepresentable {

    let controller: UIViewController
    /// "Search in book" from the selection menu.
    var searchInBook: () -> Void = {}

    func makeUIViewController(context: Context) -> Container {
        let container = Container()
        container.set(controller)
        container.seek = searchInBook
        return container
    }

    func updateUIViewController(_ container: Container, context: Context) {
        container.set(controller)
        container.seek = searchInBook
    }

    final class Container: UIViewController {
        private var kind: UIViewController?
        var seek: () -> Void = {}

        /// Target of the custom menu item (``BookController/menuSearch``): the selection in the web view
        /// passes the action up the responder chain to here.
        @objc func searchInBook(_ sender: Any?) {
            seek()
        }

        func set(_ new: UIViewController) {
            guard kind !== new else { return }
            if let old = kind {
                old.willMove(toParent: nil)
                old.view.removeFromSuperview()
                old.removeFromParent()
            }
            kind = new
            addChild(new)
            new.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(new.view)
            NSLayoutConstraint.activate([
                new.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                new.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                new.view.topAnchor.constraint(equalTo: view.topAnchor),
                new.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            new.didMove(toParent: self)
        }
    }
}
