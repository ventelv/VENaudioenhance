import AppKit
import SwiftUI
import VENCore

@main
struct VENApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var live: LiveController
    @StateObject private var queue: MasteringQueue
    @StateObject private var speech = SpeechModels()
    @StateObject private var system: SystemSupport

    init() {
        let live = LiveController()
        let system = SystemSupport()
        let queue = MasteringQueue()
        system.installCoughKey(live)
        AppDelegate.openFiles = { urls in
            queue.add(urls)
            NotificationCenter.default.post(name: .venShowMainWindow, object: nil)
        }
        _live = StateObject(wrappedValue: live)
        _queue = StateObject(wrappedValue: queue)
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
                .environmentObject(speech)
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

/// Opening the app again from Finder or Spotlight shows the main window (there's no Dock icon). Files dropped
/// on the app icon or opened with it go to the mastering queue.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openFiles: (([URL]) -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .venShowMainWindow, object: nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.openFiles?(urls)
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
        // The bundle's path goes in as an AppleScript string, quoted for the shell by `quoted form of`, so no
        // folder name can turn into a command run as root. A downloaded app's files carry the quarantine mark,
        // which cp keeps; the audio service may refuse a quarantined plug-in, so it's cleared on the copy.
        let source = driver.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            set src to "\(source)"
            set dest to "/Library/Audio/Plug-Ins/HAL/VENMic.driver"
            do shell script "rm -rf " & quoted form of dest & " && cp -R " & quoted form of src & " " & quoted form of dest & ¬
                " && xattr -dr com.apple.quarantine " & quoted form of dest & ¬
                " && chown -R root:wheel " & quoted form of dest & " && killall coreaudiod" ¬
                with prompt "VEN Audio Enhance wants to install the VEN Enhanced Mic audio driver." with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            installMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Install was cancelled."
        } else {
            installMessage = "Installed. VEN Enhanced Mic is now available in every app."
        }
    }

    /// Removes VEN Enhanced Mic from CoreAudio, asking for the admin password.
    func uninstallDriver() {
        let script = """
            do shell script "rm -rf '/Library/Audio/Plug-Ins/HAL/VENMic.driver' && killall coreaudiod" ¬
                with prompt "VEN Audio Enhance wants to remove the VEN Enhanced Mic audio driver." with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            installMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Uninstall was cancelled."
        } else {
            installMessage = "Removed. To remove the app too, move it from Applications to the Trash."
        }
    }
}
