import AppKit
import Combine
import SMCKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { observeControl() }
    }
    private var controlObserver: AnyCancellable?
    private var wasControlling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // While controlling fans, closing the window keeps the app in the menu bar; otherwise it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.isControlling ?? false)
    }

    // Reopening the app (Dock, Spotlight) after its window was closed brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    // If fan control ends while the window is closed, the menu bar item disappears too;
    // quit so the app is not left running with nothing on screen.
    private func observeControl() {
        controlObserver = model?.$modes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let model = self.model else { return }
            let controlling = model.isControlling
            if self.wasControlling, !controlling, self.mainWindow?.isVisible != true {
                NSApp.terminate(nil)
            }
            self.wasControlling = controlling
        }
    }

    // Quitting returns the fans to automatic so they are never left forgotten at a low speed.
    func applicationWillTerminate(_ notification: Notification) {
        model?.releaseAllFans()
    }
}

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Fan Control", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        // The window tracks its content size, so there is no leftover empty space.
        .windowResizability(.contentSize)

        // Shown in the menu bar only while fan control is active.
        MenuBarExtra(isInserted: Binding(get: { model.isControlling }, set: { _ in })) {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: "fan")
            Text(menuBarTitle)
        }
    }

    private var menuBarTitle: String {
        guard let fastest = model.fans.map(\.actualRPM).max() else { return "" }
        return "\(Int(fastest))"
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.fans) { fan in
            Text("\(fan.name): \(Int(fan.actualRPM)) RPM")
        }
        if let cpu = model.sensors.first(where: { $0.id == "cpu.avg" }) {
            Text("\(cpu.name): \(Int(cpu.celsius.rounded()))°C")
        }
        Divider()
        Button("Open Fan Control") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Set All Fans to Auto") {
            for fan in model.fans { model.setMode(.auto, for: fan) }
        }
        .disabled(!model.helperState.canControl)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
