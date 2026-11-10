import SwiftUI
import AppKit
import Carbon

private enum SettingsTab: String, CaseIterable {
    case general = "General", annotations = "Annotations", privacy = "Privacy & about"
    var symbol: String { switch self { case .general: "slider.horizontal.3"; case .annotations: "paintbrush"; case .privacy: "checkmark.shield" } }
    var hint: String { switch self { case .general: "Capture, saving and startup"; case .annotations: "Default colours and sizes for the editor"; case .privacy: "How FastShot handles your screenshots" } }
}
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var tab: SettingsTab = .general
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.preferences.error ?? model.capture.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    if model.capture.permissionNeeded {
                        Button("Request access") { model.capture.requestPermission() }.disabled(model.capture.busy)
                        Button("System Settings") { model.capture.openPrivacy() }
                        Button("Reveal FastShot") { model.capture.revealApp() }
                    }
                    Button { model.capture.message = nil; model.preferences.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 10)
            }
            if !model.preferences.value.onboardingComplete { welcome }
            else {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 9) { Image(systemName: tab.symbol).foregroundStyle(.blue); Text(tab.rawValue) }.font(.system(size: 22, weight: .semibold))
                                Text("\(tab.hint). Changes are saved automatically.").font(.callout).foregroundStyle(.secondary)
                            }
                            switch tab { case .general: general; case .annotations: annotations; case .privacy: privacy }
                        }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                    }.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12))).padding(.trailing, 10).padding(.bottom, 10)
                }
            }
        }.frame(minWidth: 800, minHeight: 620)
            .background(scheme == .dark ? Color(red: 0.12, green: 0.14, blue: 0.16) : Color(red: 0.94, green: 0.96, blue: 0.97)).tint(.blue)
            .onAppear { model.capture.reopenSettings = { openWindow(id: "settings") } }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Brand.logoImage).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) { Text("FastShot").font(.system(size: 17, weight: .semibold)); Text("Press \(model.preferences.value.shortcutLabel) to capture").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            ForEach(CaptureMode.allCases) { mode in
                Button { model.capture.begin(mode) } label: { Label(mode.title, systemImage: mode.symbol).padding(.vertical, 3) }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(mode == .region ? (scheme == .dark ? Color.white : Color.black) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(mode == .region ? Color.clear : Color.primary.opacity(0.12)))
                    .foregroundStyle(mode == .region ? (scheme == .dark ? Color.black : Color.white) : Color.primary).disabled(model.capture.busy).help("Capture a \(mode.rawValue)")
            }
        }.padding(.horizontal, 22).padding(.vertical, 18)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.symbol).font(.system(size: 13, weight: item == tab ? .medium : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                        .background(item == tab ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).foregroundStyle(item == tab ? Color.primary : Color.secondary)
            }
            Spacer()
            Button { NSApp.keyWindow?.close() } label: { Label("Close window", systemImage: "xmark").font(.callout) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(10)
            Text("Version 1.0 · Native macOS").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.bottom, 16)
        }.padding(.horizontal, 12).frame(width: 190)
    }
    private var general: some View {
        VStack(spacing: 26) {
            SettingsCard("Capture", symbol: "rectangle.dashed", description: "How screenshots are started.") {
                settingRow("Capture shortcut", detail: "Works from any app while FastShot is running.") { ShortcutRecorder(model: model) }
                if let error = model.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                Divider()
                settingRow("Default capture mode", detail: "Used by the shortcut and menu bar.") {
                    Picker("Default capture mode", selection: $model.preferences.value.defaultMode) { ForEach(CaptureMode.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 225)
                }
                Divider()
                preferenceToggle("Show magnifier while selecting", detail: "Zoomed pixels, coordinates and colour for precise edges.", binding: $model.preferences.value.showMagnifier)
                Divider()
                preferenceToggle("Click to select a window", detail: "Click without dragging to capture a visible window.", binding: $model.preferences.value.autoSelectWindow)
            }
            SettingsCard("Saving", symbol: "folder", description: "Used by Save and Quick save (⌘⇧S).") {
                settingRow("Format", detail: "Choose either format in Save As.") {
                    Picker("Save format", selection: $model.preferences.value.format) { Text("PNG").tag("png"); Text("JPEG").tag("jpeg") }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                if model.preferences.value.format == "jpeg" { valueSlider("JPEG quality", value: $model.preferences.value.jpegQuality, range: 40...100, suffix: "%") }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("Save folder").fontWeight(.medium)
                    HStack {
                        Text(model.preferences.value.directoryPath ?? "Documents/FastShot (default)").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        Button("Browse…") { model.preferences.chooseDirectory() }
                        if model.preferences.value.directoryBookmark != nil { Button { model.preferences.value.directoryBookmark = nil; model.preferences.value.directoryPath = nil } label: { Image(systemName: "arrow.counterclockwise") }.help("Use default folder") }
                    }
                    Text("Quick save writes here without asking.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("File name").fontWeight(.medium)
                    TextField("Screenshot-{date}-{time}", text: $model.preferences.value.filenameTemplate).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    Text(filenamePreview).font(.caption).foregroundStyle(filenameValid ? Color.secondary : .red)
                    Text("{date} {time} {n} {YYYY} {MM} {DD} {hh} {mm} {ss} {width} {height}").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            SettingsCard("Appearance", symbol: "paintpalette") {
                settingRow("Theme") { Picker("Theme", selection: $model.preferences.value.theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.labelsHidden().pickerStyle(.segmented).frame(width: 220) }
            }
            SettingsCard("Startup & background", symbol: "power") {
                preferenceToggle("Keep running when closed", detail: "FastShot stays in the menu bar so the shortcut keeps working.", binding: $model.preferences.value.keepRunning)
                Divider()
                preferenceToggle("Launch at login", detail: "Start in the menu bar when you sign in.", binding: Binding(get: { model.preferences.launchAtLogin }, set: { model.preferences.setLaunchAtLogin($0) }))
            }
        }
    }
    private var annotations: some View {
        VStack(spacing: 26) {
            HStack(spacing: 30) {
                RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: NSColor(hex: model.preferences.value.annotationColor)), lineWidth: model.preferences.value.strokeWidth).frame(width: 85, height: 55)
                Text("Aa").font(.system(size: min(48, model.preferences.value.fontSize), weight: .semibold)).foregroundStyle(Color(nsColor: NSColor(hex: model.preferences.value.annotationColor)))
                VStack(alignment: .leading, spacing: 6) { Text("Redacted").font(.caption).foregroundStyle(.secondary); Rectangle().fill(Color(nsColor: NSColor(hex: model.preferences.value.redactColor))).frame(width: 100, height: 18) }; Spacer()
            }.padding(26).frame(maxWidth: .infinity).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
            SettingsCard("Annotations", symbol: "paintbrush", description: "Defaults for new shapes, arrows and text. Change them per item in the editor.") {
                swatches("Colour", selection: $model.preferences.value.annotationColor); Divider()
                valueSlider("Stroke width", value: $model.preferences.value.strokeWidth, range: 1...30, suffix: "px"); Divider()
                valueSlider("Text size", value: $model.preferences.value.fontSize, range: 10...120, suffix: "px")
            }
            SettingsCard("Redaction", symbol: "eye.slash", description: "Opaque fills permanently replace pixels in your exported image.") { swatches("Colour", selection: $model.preferences.value.redactColor) }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 26) {
            Label { VStack(alignment: .leading, spacing: 5) { Text("Redact is permanent. Blur and pixelate are not.").fontWeight(.semibold); Text("Redact replaces pixels with solid colour. Blur and pixelate are visual effects; text beneath them may be recoverable.").foregroundStyle(.secondary) } } icon: { Image(systemName: "checkmark.shield").foregroundStyle(.blue) }.padding(16).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            SettingsCard("Your data", symbol: "checkmark.shield") {
                ForEach(["Works fully offline. No account, uploads or analytics.", "Screenshots stay in memory until you copy or save. No automatic files or history.", "Clipboard managers may keep copies of anything you copy.", "Exported images are freshly encoded without source metadata.", "Text recognition uses Apple Vision on your Mac, after redaction."], id: \.self) { text in
                    HStack(alignment: .top, spacing: 10) { Circle().fill(.blue).frame(width: 5, height: 5).padding(.top, 6); Text(text).foregroundStyle(.secondary) }
                }
            }
            SettingsCard("Screen recording", symbol: "display") {
                Text("macOS requires Screen & System Audio Recording access. FastShot does not record audio or video.").foregroundStyle(.secondary)
                HStack {
                    Button(model.capture.busy ? "Requesting access…" : "Allow screen recording") { model.capture.requestPermission() }.disabled(model.capture.busy)
                    Button("System Settings") { model.capture.openPrivacy() }
                    Button("Reveal FastShot") { model.capture.revealApp() }
                }
                Text("If FastShot is missing from the list, reveal this app and add it with the + button in System Settings. Then quit and reopen FastShot if requested.").font(.caption).foregroundStyle(.secondary)
                Button("Retry capture") { model.capture.begin() }.disabled(model.capture.busy)
            }
            SettingsCard("About", symbol: "info.circle") {
                HStack(spacing: 12) {
                    Image(nsImage: Brand.logoImage).resizable().frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 4) { Text("FastShot 1.0").fontWeight(.medium); Text("Native macOS · SwiftUI & AppKit").font(.caption).foregroundStyle(.secondary) }; Spacer()
                    Button("Show welcome") { model.preferences.value.onboardingComplete = false }
                    Button("Quit FastShot", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: Brand.logoImage).resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 9) { Text("Welcome to FastShot").font(.system(size: 28, weight: .semibold)); Text("Capture, mark up, hide what’s private, and share.").font(.title3).foregroundStyle(.secondary) }
            Label("Press \(model.preferences.value.shortcutLabel) anywhere. Drag an area, then copy.", systemImage: "rectangle.dashed")
            Label("Redact permanently replaces pixels. Blur and pixelate are visual effects.", systemImage: "checkmark.shield")
            Label("FastShot stays in your menu bar when you close this window.", systemImage: "menubar.rectangle")
            Text("Everything works on your Mac. No account, uploads or analytics.").foregroundStyle(.secondary)
            HStack {
                Button("Skip") { model.preferences.value.onboardingComplete = true }; Spacer()
                Button(model.capture.busy ? "Requesting access…" : "Allow screen recording") { model.capture.requestPermission() }.disabled(model.capture.busy)
                Button("Take a screenshot") { model.preferences.value.onboardingComplete = true; model.capture.begin(.region) }.buttonStyle(.borderedProminent)
            }
        }.font(.body).padding(36).frame(maxWidth: 650).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.1))).frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private var filenameValid: Bool { (try? Filename.render(model.preferences.value.filenameTemplate, width: 1920, height: 1080)) != nil }
    private var filenamePreview: String {
        do { return "Preview: " + (try Filename.render(model.preferences.value.filenameTemplate, width: 1920, height: 1080)) + (model.preferences.value.format == "jpeg" ? ".jpg" : ".png") }
        catch { return error.localizedDescription }
    }
    private func settingRow<C: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 18) { VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 8); control() }
    }
    private func preferenceToggle(_ title: String, detail: String, binding: Binding<Bool>) -> some View { settingRow(title, detail: detail) { Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small) } }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 10) { HStack { Text(title).fontWeight(.medium); Spacer(); Text("\(Int(value.wrappedValue))\(suffix)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }; Slider(value: value, in: range, step: 1).accessibilityLabel(title) }
    }
    private func swatches(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).fontWeight(.medium)
            HStack(spacing: 12) {
                ForEach(annotationPalette, id: \.self) { hex in
                    Button { selection.wrappedValue = hex } label: { Circle().fill(Color(nsColor: NSColor(hex: hex))).frame(width: 26, height: 26).overlay(Circle().stroke(.gray.opacity(0.4))).overlay { if selection.wrappedValue == hex { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(hex == "#ffffff" || hex == "#facc15" ? .black : .white) } } }.buttonStyle(.plain).accessibilityLabel("Colour \(hex)").accessibilityAddTraits(selection.wrappedValue == hex ? .isSelected : [])
                }
            }
        }
    }
}
private struct SettingsCard<C: View>: View {
    let title: String; let symbol: String; let description: String?; let content: C
    init(_ title: String, symbol: String, description: String? = nil, @ViewBuilder content: () -> C) { self.title = title; self.symbol = symbol; self.description = description; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) { Image(systemName: symbol).foregroundStyle(.blue).frame(width: 18).padding(.top, 1); VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 13, weight: .semibold)); if let description { Text(description).font(.caption).foregroundStyle(.secondary) } } }
            VStack(alignment: .leading, spacing: 18) { content }.font(.system(size: 12)).padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct ShortcutRecorder: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> RecorderButton { let b = RecorderButton(); b.model = model; b.bezelStyle = .rounded; b.target = b; b.action = #selector(RecorderButton.record); return b }
    func updateNSView(_ view: RecorderButton, context: Context) { if !view.recording { view.title = model.preferences.value.shortcutLabel } }
    final class RecorderButton: NSButton {
        var model: AppModel?; var recording = false
        override var acceptsFirstResponder: Bool { true }
        @objc func record() { recording = true; model?.recordingShortcut = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { recording = false; model?.recordingShortcut = false; title = model?.preferences.value.shortcutLabel ?? ""; return super.resignFirstResponder() }
        override func keyDown(with event: NSEvent) {
            guard recording, let model else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; model.recordingShortcut = false; title = model.preferences.value.shortcutLabel; return }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option), let char = event.charactersIgnoringModifiers, char.count == 1 else { title = "Include ⌘, ⌃ or ⌥"; return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }; if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            let label = (flags.contains(.control) ? "⌃ " : "") + (flags.contains(.option) ? "⌥ " : "") + (flags.contains(.shift) ? "⇧ " : "") + (flags.contains(.command) ? "⌘ " : "") + char.uppercased()
            model.updateShortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: label); recording = false; model.recordingShortcut = false; title = model.preferences.value.shortcutLabel
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    }
}
