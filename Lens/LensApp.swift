//
//  LensApp.swift
//  Lens
//
//  Created by Siva G on 10/08/26.
//

import AppKit
import SwiftUI

@MainActor
final class LensApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: LensModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LensApp: App {
    @NSApplicationDelegateAdaptor(LensApplicationDelegate.self) private var applicationDelegate
    @State private var model = LensModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    applicationDelegate.model = model
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                        model.prepareUITestFixture()
                    } else {
                        model.startEngine()
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Session…") { model.openSession() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Session…") { model.saveSession() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("Proxy") {
                Button(model.captures.isCapturePaused ? "Resume Capture" : "Pause Capture") { model.toggleCapture() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Clear Flows") { model.clearFlows() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Button("Local Mappings…") { model.showingMappings = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Android Devices…") { model.showingDevices = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
