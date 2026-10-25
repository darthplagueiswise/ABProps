import UIKit

/// System share sheet for exported document files.
enum FileShare {
    static func present(_ url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let controller = (window.windows.first(where: { $0.isKeyWindow })
                                ?? window.windows.first)?.rootViewController else { return }
        var visible = controller
        while let presented = visible.presentedViewController { visible = presented }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = visible.view
            popover.sourceRect = CGRect(x: visible.view.bounds.midX,
                                        y: visible.view.bounds.maxY - 20, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        visible.present(sheet, animated: true)
    }
}
