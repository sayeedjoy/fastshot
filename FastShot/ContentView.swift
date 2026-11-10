import SwiftUI
import AppKit
import Carbon

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", shortcuts = "Shortcuts", saving = "Saving", annotations = "Annotations", privacy = "Privacy & Security", about = "About"
    var id: Self { self }
    var symbol: String { switch self { case .general: "gearshape.fill"; case .shortcuts: "keyboard.fill"; case .saving: "folder.fill"; case .annotations: "pencil.tip.crop.circle.fill"; case .privacy: "hand.raised.fill"; case .about: "info.circle.fill" } }
    var tint: Color { switch self { case .general: .gray; case .shortcuts: .purple; case .saving: .blue; case .annotations: .orange; case .privacy: .indigo; case .about: .secondary } }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var tab: SettingsTab? = .general
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if model.preferences.value.onboardingComplete { settings } else { welcome }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            model.capture.reopenSettings = { openWindow(id: "settings") }
            model.capture.refreshScreenPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.capture.refreshScreenPermission()
        }
    }

    // MARK: Layout

    private var settings: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $tab) { item in
                Label { Text(item.rawValue) } icon: { SidebarIcon(symbol: item.symbol, tint: item.tint) }.tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                if tab == .about {
                    about
                } else {
                    Form {
                        if let message = model.preferences.error ?? model.capture.message { banner(message) }
                        switch tab ?? .general {
                        case .general: general
                        case .shortcuts: shortcuts
                        case .saving: saving
                        case .annotations: annotations
                        case .privacy: privacy
                        case .about: EmptyView()
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle((tab ?? .general).rawValue)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ForEach(CaptureMode.allCases) { mode in
                            Button { model.capture.begin(mode) } label: { Label(mode.title, systemImage: mode.symbol) }
                        }
                    } label: {
                        Label(model.capture.busy ? "Capturing…" : "Capture", systemImage: "viewfinder")
                    } primaryAction: {
                        model.capture.begin()
                    }
                    .disabled(model.capture.busy)
                    .help("Take a screenshot. Open the menu to choose a capture mode.")
                }
            }
        }
    }
    private func banner(_ message: String) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: model.capture.permissionNeeded ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(model.capture.permissionNeeded ? Color.orange : Color.accentColor)
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { model.capture.message = nil; model.preferences.error = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
            }
            if model.capture.permissionNeeded { permissionButtons }
        }
    }
    private var permissionButtons: some View {
        HStack {
            Button(model.capture.busy ? "Requesting Access…" : "Request Access") { model.capture.requestPermission() }.disabled(model.capture.busy)
            Button("Open System Settings") { model.capture.openPrivacy() }
            Button("Reveal in Finder") { model.capture.revealApp() }
        }
    }

    // MARK: Panes

    @ViewBuilder private var general: some View {
        Section {
            Picker(selection: $model.preferences.value.defaultMode) {
                ForEach(CaptureMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            } label: {
                Text("Default capture mode")
                Text("Used by the Capture button and default capture shortcut.")
            }
            Toggle(isOn: $model.preferences.value.showCaptureModePanel) {
                Text("Show capture mode panel")
                Text("Show the top Region, Window and Display panel when capture starts. Keys 1, 2 and 3 work when hidden.")
            }
        } header: { Text("Capture") }
        Section {
            Toggle(isOn: $model.preferences.value.showMagnifier) {
                Text("Show magnifier while selecting")
                Text("Zoomed pixels, coordinates and colour for precise edges.")
            }
            Toggle(isOn: $model.preferences.value.autoSelectWindow) {
                Text("Click to select a window")
                Text("Click without dragging to capture a visible window.")
            }
        }
        Section {
            Toggle(isOn: $model.preferences.value.showAfterCapture) {
                Text("Show screenshot after capture")
                Text("Open area captures in the editor or a thumbnail. Other captures show a thumbnail.")
            }
            Toggle(isOn: $model.preferences.value.copyAfterCapture) {
                Text("Copy to clipboard automatically")
                Text("Copy the screenshot immediately, before any edits.")
            }
            Toggle(isOn: $model.preferences.value.saveAfterCapture) {
                Text("Save to folder automatically")
                Text("Save the screenshot immediately, before any edits, using your Saving settings.")
            }
            if noCaptureActions {
                Label("No action selected. Screenshots will be discarded after capture.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show screenshots after capture") { model.preferences.value.showAfterCapture = true }
            }
        } header: {
            Text("After capture")
        } footer: {
            Text("These actions work independently. You can show, copy and save the same screenshot.")
        }
        Section {
            Picker("Open area captures in", selection: $model.preferences.value.areaDestination) {
                Text("Thumbnail").tag(AreaDestination.thumbnail)
                Text("Editor").tag(AreaDestination.editor)
            }
            .disabled(!model.preferences.value.showAfterCapture)
            Picker("Dismiss thumbnail", selection: $model.preferences.value.thumbnailDismissal) {
                ForEach(ThumbnailDismissal.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.preferences.value.showAfterCapture)
        } header: {
            Text("Screenshot preview")
        } footer: {
            Text(model.preferences.value.showAfterCapture
                 ? "The editor lets you annotate before copying or saving. Thumbnails offer Edit, Pin, Copy and Quick Save. Automatic dismissal pauses while the pointer is over the thumbnail."
                 : "Turn on Show screenshot after capture to use the editor or thumbnail.")
        }
        Section("Appearance") {
            Picker("Theme", selection: $model.preferences.value.theme) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.menu)
        }
        Section("Startup") {
            Toggle(isOn: $model.preferences.value.keepRunning) {
                Text("Keep running when closed")
                Text("FastShot stays in the menu bar so the shortcut keeps working.")
            }
            Toggle("Launch at login", isOn: Binding(get: { model.preferences.launchAtLogin }, set: { model.preferences.setLaunchAtLogin($0) }))
        }
    }
    @ViewBuilder private var shortcuts: some View {
        Section {
            ForEach(CaptureCommand.allCases) { action in
                LabeledContent(action.title) {
                    HStack {
                        ShortcutRecorder(model: model, command: action).fixedSize()
                        if model.preferences.value.binding(for: action) != nil {
                            Button { model.updateShortcut(action, binding: nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).accessibilityLabel("Clear \(action.title) shortcut")
                        }
                    }
                }
            }
            if let error = model.shortcutError { Text(error).font(.callout).foregroundStyle(.red) }
        } header: {
            Text("Keyboard shortcuts")
        } footer: {
            Text("Click a shortcut to record a new combination. Include ⌘, ⌃ or ⌥. Press Escape to cancel, or use the clear button to remove a shortcut.")
        }
    }

    @ViewBuilder private var saving: some View {
        Section {
            Picker("Format", selection: $model.preferences.value.format) { Text("PNG").tag("png"); Text("JPEG").tag("jpeg") }.pickerStyle(.segmented)
            if model.preferences.value.format == "jpeg" {
                valueSlider("JPEG quality", value: $model.preferences.value.jpegQuality, range: 40...100, suffix: "%")
            }
        } footer: { Text("Save As lets you pick either format each time.") }
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    if model.preferences.value.directoryBookmark != nil {
                        Button { model.preferences.value.directoryBookmark = nil; model.preferences.value.directoryPath = nil } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("Use the default folder").accessibilityLabel("Use the default save folder")
                    }
                    Button("Choose…") { model.preferences.chooseDirectory() }
                }
            } label: {
                Text("Save folder")
                Label(folderName, systemImage: "folder.fill").lineLimit(1).truncationMode(.middle)
            }
            TextField("File name", text: $model.preferences.value.filenameTemplate, prompt: Text("Screenshot-{date}-{time}"))
                .font(.body.monospaced())
        } header: {
            Text("Quick Save")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(filenamePreview).foregroundStyle(filenameValid ? Color.secondary : .red)
                Text("Tokens: {date} {time} {n} {YYYY} {MM} {DD} {hh} {mm} {ss} {width} {height}").font(.caption.monospaced())
            }
        }
    }
    @ViewBuilder private var annotations: some View {
        Section {
            HStack(spacing: 28) {
                Spacer()
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: NSColor(hex: model.preferences.value.annotationColor)), lineWidth: model.preferences.value.strokeWidth).frame(width: 80, height: 52)
                Text("Aa").font(.system(size: min(44, model.preferences.value.fontSize), weight: .semibold)).foregroundStyle(Color(nsColor: NSColor(hex: model.preferences.value.annotationColor)))
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: NSColor(hex: model.preferences.value.redactColor))).frame(width: 90, height: 16)
                Spacer()
            }.frame(height: 72).accessibilityHidden(true)
        }
        Section {
            LabeledContent("Colour") { swatches(selection: $model.preferences.value.annotationColor) }
            valueSlider("Stroke width", value: $model.preferences.value.strokeWidth, range: 1...30, suffix: " px")
            valueSlider("Text size", value: $model.preferences.value.fontSize, range: 10...120, suffix: " px")
        } header: { Text("Shapes, Arrows & Text") } footer: { Text("Defaults for new annotations. Use Colour & size in the editor’s tool palette to adjust individual items.") }
        Section {
            LabeledContent("Colour") { swatches(selection: $model.preferences.value.redactColor) }
        } header: { Text("Redaction") } footer: { Text("Opaque fills permanently replace pixels in the exported image.") }
    }
    @ViewBuilder private var privacy: some View {
        Section {
            LabeledContent {
                if model.capture.screenAccessGranted {
                    Label("All set", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button(model.capture.busy ? "Requesting…" : "Allow…") { model.capture.requestPermission() }.disabled(model.capture.busy)
                }
            } label: {
                Text("Screen & System Audio Recording")
                Text("Required by macOS to take screenshots. FastShot never records audio or video.")
            }
            if !model.capture.screenAccessGranted {
                HStack {
                    Button("Open System Settings") { model.capture.openPrivacy() }
                    Button("Reveal in Finder") { model.capture.revealApp() }
                    Spacer()
                    Button("Retry Capture") { model.capture.begin() }.disabled(model.capture.busy)
                }
            }
        } header: { Text("Permissions") } footer: {
            if !model.capture.screenAccessGranted {
                Text("If FastShot is missing from the list, reveal the app and add it with the + button, then quit and reopen FastShot if asked.")
            }
        }
        Section("Your Data") {
            privacyRow("wifi.slash", "Works fully offline", "No account, uploads or analytics.")
            privacyRow("memorychip", "Nothing kept in the background", "Screenshots stay in memory until you copy or save them.")
            privacyRow("eye.slash", "Redact is permanent", "Blur and pixelate are visual effects; text beneath them may be recoverable.")
            privacyRow("doc.badge.gearshape", "Clean exports", "Images are freshly encoded without source metadata.")
            privacyRow("text.viewfinder", "On-device text recognition", "Apple Vision reads text on your Mac, after redaction.")
            privacyRow("doc.on.clipboard", "Clipboard", "Clipboard managers may keep copies of anything you copy.")
        }
    }
    private var about: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if let message = model.preferences.error ?? model.capture.message { banner(message) }
                    VStack(spacing: 5) {
                        Image(nsImage: Brand.logoImage)
                            .resizable().scaledToFit().frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                            .padding(.bottom, 4)
                        Text("FastShot").font(.system(size: 26, weight: .bold))
                        Text(appVersion).font(.caption).foregroundStyle(.secondary)
                        Text("Capture. Annotate. Share.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    VStack(spacing: 3) {
                        Text("Developed by").font(.caption).foregroundStyle(.secondary)
                        Text("Sayeed Joy").font(.headline).textSelection(.enabled)
                    }
                    HStack(spacing: 10) {
                        aboutLink("sayeedjoy.com", symbol: "globe", destination: "https://sayeedjoy.com")
                        aboutLink("GitHub", symbol: "chevron.left.forwardslash.chevron.right", destination: "https://github.com/sayeedjoy/fastshot", image: Brand.githubImage)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    CheckForUpdatesButton(updates: model.updates)
                        .buttonStyle(.bordered).controlSize(.small)
                    if !model.updates.isConfigured {
                        Text("Updates are available in the GitHub release build.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Made for macOS. Screenshots and text recognition stay on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: 300)
                    Divider()
                    HStack(spacing: 16) {
                        Button("Welcome Guide") { model.preferences.value.onboardingComplete = false }
                        aboutLink("Report an issue", symbol: "bubble.left.and.bubble.right", destination: "https://github.com/sayeedjoy/fastshot/issues")
                        Button("Quit FastShot") { NSApp.terminate(nil) }
                    }
                    .buttonStyle(.link).font(.callout)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 40))
                .padding(20)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    @ViewBuilder private func aboutLink(_ title: String, symbol: String, destination: String, image: NSImage? = nil) -> some View {
        if let url = URL(string: destination) {
            Link(destination: url) {
                Label {
                    Text(title)
                } icon: {
                    if let image {
                        Image(nsImage: image).renderingMode(.template).resizable()
                            .scaledToFit().frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: symbol)
                    }
                }
            }
            .help("Open \(destination) in your browser")
            .accessibilityLabel("\(title), opens in browser")
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Image(nsImage: Brand.logoImage).resizable().frame(width: 76, height: 76).accessibilityHidden(true)
                Text("Welcome to FastShot").font(.largeTitle.weight(.bold)).padding(.top, 18)
                Text("Capture, mark up, hide what’s private, and share.").font(.title3).foregroundStyle(.secondary).padding(.top, 4)
                VStack(alignment: .leading, spacing: 20) {
                    featureRow("rectangle.dashed", .blue, "Capture anything", "Press \(model.preferences.value.captureShortcutLabel) anywhere, drag an area, then copy.")
                    featureRow("eye.slash.fill", .indigo, "Hide what’s private", "Redact permanently replaces pixels. Blur and pixelate are visual effects.")
                    featureRow("text.viewfinder", .orange, "Copy text from images", "Recognise text on your Mac with Apple Vision.")
                    featureRow("menubar.rectangle", .gray, "Always at hand", "FastShot stays in the menu bar when you close this window.")
                }.frame(maxWidth: 440, alignment: .leading).padding(.top, 34)
                Spacer(minLength: 24)
                VStack(spacing: 10) {
                    Button { model.preferences.value.onboardingComplete = true; model.capture.begin(.region) } label: { Text("Take a Screenshot").frame(width: 240) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    if model.capture.screenAccessGranted {
                        Label("Screen recording access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(model.capture.busy ? "Requesting Access…" : "Allow Screen Recording") { model.capture.requestPermission() }.disabled(model.capture.busy).buttonStyle(.link)
                    }
                    if let message = model.capture.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    Button("Not Now") { model.preferences.value.onboardingComplete = true }.buttonStyle(.link).foregroundStyle(.secondary)
                }
                Text("Everything works on your Mac. No account, uploads or analytics.").font(.footnote).foregroundStyle(.tertiary).padding(.top, 18).padding(.bottom, 28)
            }
            .padding(.horizontal, 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }

    // MARK: Building blocks

    private var noCaptureActions: Bool {
        !model.preferences.value.showAfterCapture && !model.preferences.value.copyAfterCapture && !model.preferences.value.saveAfterCapture
    }
    private var folderName: String { model.preferences.value.directoryPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/Documents/FastShot" }
    private var filenameValid: Bool { (try? Filename.render(model.preferences.value.filenameTemplate, width: 1920, height: 1080)) != nil }
    private var filenamePreview: String {
        do { return "Preview: " + (try Filename.render(model.preferences.value.filenameTemplate, width: 1920, height: 1080)) + (model.preferences.value.format == "jpeg" ? ".jpg" : ".png") }
        catch { return error.localizedDescription }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 1).labelsHidden().frame(minWidth: 80, idealWidth: 160, maxWidth: 200).accessibilityLabel(title)
                Text("\(Int(value.wrappedValue))\(suffix)").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }
    private func swatches(selection: Binding<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(annotationPalette, id: \.self) { hex in
                let selected = selection.wrappedValue == hex
                Button { selection.wrappedValue = hex } label: {
                    Circle().fill(Color(nsColor: NSColor(hex: hex)))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                        .overlay { if selected { Circle().fill(hex == "#ffffff" || hex == "#facc15" ? Color.black : .white).frame(width: 6, height: 6) } }
                        .frame(width: 22, height: 22)
                        .padding(3).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(hex).accessibilityLabel("Colour \(hex)").accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
    private func privacyRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label { Text(title); Text(detail) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
    }
    private func featureRow(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// System Settings–style coloured tile behind a sidebar glyph.
private struct SidebarIcon: View {
    let symbol: String; let tint: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 20, height: 20).background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
private struct ShortcutRecorder: NSViewRepresentable {
    let model: AppModel
    let command: CaptureCommand
    func makeNSView(context: Context) -> RecorderButton { let b = RecorderButton(); b.model = model; b.command = command; b.bezelStyle = .rounded; b.target = b; b.action = #selector(RecorderButton.record); return b }
    func updateNSView(_ view: RecorderButton, context: Context) {
        if !view.recording { view.title = model.preferences.value.binding(for: command)?.label ?? "Record Shortcut" }
        view.setAccessibilityLabel("\(command.title) shortcut")
        view.setAccessibilityHelp("Click to record. Press Escape to cancel.")
    }
    final class RecorderButton: NSButton {
        var command: CaptureCommand = .capture
        var model: AppModel?; var recording = false
        override var acceptsFirstResponder: Bool { true }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { recording = false; model?.recordingShortcut = false }
            super.viewWillMove(toWindow: newWindow)
        }
        @objc func record() { recording = true; model?.recordingShortcut = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { recording = false; model?.recordingShortcut = false; title = model?.preferences.value.binding(for: command)?.label ?? "Record Shortcut"; return super.resignFirstResponder() }
        override func keyDown(with event: NSEvent) {
            guard recording, let model else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; model.recordingShortcut = false; title = (model.preferences.value.binding(for: command)?.label ?? "Record Shortcut"); return }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option), let char = event.charactersIgnoringModifiers, char.count == 1 else { title = "Include ⌘, ⌃ or ⌥"; return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }; if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            let label = (flags.contains(.control) ? "⌃ " : "") + (flags.contains(.option) ? "⌥ " : "") + (flags.contains(.shift) ? "⇧ " : "") + (flags.contains(.command) ? "⌘ " : "") + char.uppercased()
            model.updateShortcut(command, binding: ShortcutBinding(key: UInt32(event.keyCode), modifiers: modifiers, label: label)); recording = false; model.recordingShortcut = false; title = (model.preferences.value.binding(for: command)?.label ?? "Record Shortcut")
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    }
}
