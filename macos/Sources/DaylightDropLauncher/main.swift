import Cocoa
import DaylightDropKit
import DaylightDropTransport

@MainActor
func main() {
    let app = NSApplication.shared
    let delegate = DaylightDropAppDelegate.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

main()
