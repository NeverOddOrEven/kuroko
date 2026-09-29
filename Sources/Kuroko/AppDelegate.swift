import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var menu: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = MenuController(controller: controller)
        controller.onStateChange = { [weak menu] in menu?.updateIcon() }
        self.menu = menu
        controller.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}
