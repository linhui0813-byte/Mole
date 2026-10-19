import AppKit

enum DashboardBrand {
    static let logo = load("MoleLogo", extension: "png")
    static let appIcon = load("MoleDashboard", extension: "icns")
    static let menuIcon: NSImage = {
        let image = load("MoleMenuTemplate", extension: "png")
        image.size = NSSize(width: 22, height: 13)
        image.isTemplate = true
        return image
    }()

    private static func load(_ name: String, extension suffix: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: suffix),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled Mole artwork. Rebuild with desktop/build.sh.")
        }
        return image
    }
}
