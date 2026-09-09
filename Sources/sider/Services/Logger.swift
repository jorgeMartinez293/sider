import Foundation
import os

/// One place for the app's diagnostics. Everything goes to the unified log under the
/// `com.jorge.sider` subsystem, so `log stream --predicate 'subsystem == "com.jorge.sider"'`
/// shows a running install's behaviour without a debug build — which matters because most
/// of what sider does (Accessibility calls against other apps, window capture) only
/// misbehaves on a real, signed, permission-granted install.
enum Logger {
    private static let log = OSLog(subsystem: "com.jorge.sider", category: "sider")

    static func log(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        #if DEBUG
        print("[sider] \(message)")
        #endif
    }
}
