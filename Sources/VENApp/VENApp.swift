import AppKit
import SwiftUI
import VENCore

@main
struct VENApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var live: LiveController
    @StateObject private var queue = MasteringQueue()
    @StateObject private var system: SystemSupport

    init() {
        let live = LiveController()
        let system = SystemSupport()
        system.installCoughKey(live)
        _live = StateObject(wrappedValue: live)
        _system = StateObject(wrappedValue: system)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(live)
                .environmentObject(queue)
                .environmentObject(system)
        } label: {
            MenuBarLabel(icon: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("VEN Audio Enhance", id: "main") {
            MainWindow()
                .environmentObject(live)
                .environmentObject(queue)
                .environmentObject(system)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 860, height: 640)
    }

    private var menuIcon: String {
        if live.settings.mute { return "mic.slash.fill" }
        switch live.status {
        case .running: return live.recordingSince != nil ? "record.circle.fill" : "waveform.circle.fill"
        case .driverMissing, .failed, .noMicrophone: return "exclamationmark.triangle"
        default: return "waveform.circle"
        }
    }
}

extension Notification.Name {
    static let venShowMainWindow = Notification.Name("VENShowMainWindow")
}

/// Opening the app again from Finder or Spotlight shows the main window (there's no Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .venShowMainWindow, object: nil)
        return true
    }
}

/// The menu bar icon. It lives for the whole session, so it also opens the main window on request.
struct MenuBarLabel: View {
    let icon: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: icon)
            .onAppear {
                if !UserDefaults.standard.bool(forKey: "app.onboarded") {
                    UserDefaults.standard.set(true, forKey: "app.onboarded")
                    show()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .venShowMainWindow)) { _ in show() }
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Things outside the audio path: the driver install, launch at login and the cough key.
@MainActor
final class SystemSupport: ObservableObject {
    @Published var launchAtLogin: Bool
    @Published var installMessage: String?
    private var hotKey: HoldHotKey?

    init() {
        launchAtLogin = LoginItem.isEnabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            installMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    /// ⌃⌥C held down mutes the virtual mic (cough key).
    func installCoughKey(_ live: LiveController) {
        guard hotKey == nil else { return }
        hotKey = HoldHotKey(keyCode: 8 /* C */, modifiers: [.control, .option]) { [weak live] down in
            live?.settings.mute = down
        }
    }

    /// Copies the bundled driver into CoreAudio's plug-in folder, asking for the admin password.
    func installDriver() {
        guard let driver = Bundle.main.url(forResource: "VENMic", withExtension: "driver") else {
            installMessage = "The driver isn't inside this app bundle. Run scripts/install-driver.sh instead."
            return
        }
        let dest = "/Library/Audio/Plug-Ins/HAL/VENMic.driver"
        let shell = "rm -rf '\(dest)' && cp -R '\(driver.path)' '\(dest)' && chown -R root:wheel '\(dest)' && killall coreaudiod"
        let script = "do shell script \"\(shell)\" with prompt \"VEN Audio Enhance wants to install the VEN Enhanced Mic audio driver.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            installMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Install was cancelled."
        } else {
            installMessage = "Installed. VEN Enhanced Mic is now available in every app."
        }
    }
}
