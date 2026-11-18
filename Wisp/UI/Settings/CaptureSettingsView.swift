import AppKit
import SwiftUI

/// 采集设置里「几选一」卡片要的三样东西。采集模式和截图范围都是这种卡片。
private protocol CaptureChoice {
    var title: String { get }
    var symbol: String { get }
    var detail: String { get }
}

extension CaptureMode: CaptureChoice {}
extension CaptureScope: CaptureChoice {}

private struct CaptureOptionCard: View {
    let option: any CaptureChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: option.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(option.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            // Keep the hit target as large as the visual card, including its empty space.
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PrivacyPlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10)
                               : Color.primary.opacity(hovering ? 0.06 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                              lineWidth: selected ? 1.2 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            InfoButton(message: option.detail)
                .padding(.top, 7)
                .padding(.trailing, 7)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}


// MARK: - 采集

/// 读一次上下文要用到的东西：先是系统和浏览器的许可，然后是读到什么程度、
/// 哪些应用一概不读。权限排在最前面——没有它，底下几项调了也不生效。
struct CaptureSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var hasScreenRecording = Permissions.hasScreenRecording

    struct ProfileEntry {
        var key: String
        var browserName: String
        var profile: ChromeProfileInspector.Profile
    }
    @State private var browserProfiles: [ProfileEntry] = []

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "屏幕录制",
                              status: hasScreenRecording ? String(localized: "已授权") : String(localized: "未授权"),
                              granted: hasScreenRecording,
                              request: { Permissions.requestScreenRecording(); refresh() },
                              open: Permissions.openScreenRecordingSettings)
                HStack {
                    Text("浏览器自动化")
                    Spacer()
                    Button("系统设置…") { Permissions.openAutomationSettings() }
                }
            } header: {
                SettingsSectionHeader("权限", info: String(localized: "整页文字需要浏览器的 Apple Events 权限；在浏览器的 Developer 菜单中开启。"))
            }

            Section {
                if browserProfiles.isEmpty {
                    Text("没有检测到已安装的 Chromium 系浏览器配置文件。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(browserProfiles, id: \.key) { entry in
                        HStack {
                            Label(entry.profile.displayName,
                                  systemImage: entry.profile.allowsJavaScript ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.profile.allowsJavaScript ? .green : .orange)
                            Spacer()
                            Text(entry.browserName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("重新检测") { reloadProfiles() }
            } header: {
                SettingsSectionHeader("浏览器整页文字", info: String(localized: "每个 Chromium 配置文件都要单独开启；未开启时仍可读网址和截图。"))
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        CaptureOptionCard(option: mode, selected: settings.captureMode == mode) {
                            settings.captureMode = mode
                        }
                    }
                }

                if settings.captureMode == .scrollCollect && !ScrollDriver.isTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("需要辅助功能权限才能滑动采集。")
                            .font(.system(size: 10))
                        Button("去授权") { Permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            } header: {
                SettingsSectionHeader("采集模式")
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(CaptureScope.allCases) { scope in
                        CaptureOptionCard(option: scope, selected: settings.captureScope == scope) {
                            settings.captureScope = scope
                        }
                    }
                }

                if settings.captureScope == .screen {
                    ScreenHiddenAppsPicker()
                }
            } header: {
                SettingsSectionHeader("截图范围")
            }

            Section {
                HStack {
                    Text("字符数")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    TextField("", value: Binding(
                        get: { settings.pageTextLimit },
                        set: { settings.pageTextLimit = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    Spacer()
                    InfoButton(message: String(localized: "超出上限时保留开头和结尾，并标记省略。"))
                }
                .accessibilityElement(children: .contain)
            } header: {
                SettingsSectionHeader("页面文字上限")
            }

            Section {
                if settings.excludedBundleIDs.isEmpty {
                    Text("没有排除的应用").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(displayName(for: bundleID)).font(.system(size: 11))
                            Spacer()
                            Button("移除") {
                                settings.excludedBundleIDs.removeAll { $0 == bundleID }
                            }
                            .font(.system(size: 10))
                        }
                    }
                }
                Button("排除当前应用") { model.excludeCurrentApp() }
                    .disabled(model.packet?.bundleID == nil)
            } header: {
                SettingsSectionHeader("排除的应用", info: String(localized: "排除后不截图，也不读取浏览器页面；整屏截图时也会被挖掉。"))
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh(); reloadProfiles() }
    }

    private func refresh() {
        hasScreenRecording = Permissions.hasScreenRecording
    }

    private func reloadProfiles() {
        var entries: [ProfileEntry] = []
        for (bundleID, family) in BrowserTextExtractor.supported
        where family == .chromium && ChromeProfileInspector.supportsInspection(bundleID: bundleID) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                .deletingPathExtension().lastPathComponent ?? bundleID
            for profile in ChromeProfileInspector.statusSummary(bundleID: bundleID) {
                entries.append(ProfileEntry(key: "\(bundleID)/\(profile.directoryName)",
                                            browserName: name,
                                            profile: profile))
            }
        }
        browserProfiles = entries.sorted { $0.key < $1.key }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return "\(url.deletingPathExtension().lastPathComponent)  (\(bundleID))"
    }
}

/// 整屏截图时挖掉哪些应用。按应用勾而不是按窗口：窗口编号每次开关都会变，记不住。
/// 列出正在运行的普通应用，再加上勾过但此刻没开的，方便取消勾选。
private struct ScreenHiddenAppsPicker: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apps: [Entry] = []

    struct Entry: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    private let columns = [GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("整屏时不截的应用")
                    .font(.system(size: 12, weight: .medium))
                InfoButton(message: String(localized: "勾选的应用不会出现在整屏截图里。「排除的应用」任何时候都不截，在这里显示为已勾选。"))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(apps) { app in
                    let excluded = settings.isExcluded(bundleID: app.bundleID)
                    Toggle(isOn: hidden(app.bundleID, alwaysHidden: excluded)) {
                        HStack(spacing: 5) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            Text(app.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(excluded)
                    .help(excluded ? String(localized: "已在「排除的应用」里，任何时候都不截。") : app.bundleID)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
    }

    private func hidden(_ bundleID: String, alwaysHidden: Bool) -> Binding<Bool> {
        Binding(
            get: { alwaysHidden || settings.screenHiddenBundleIDs.contains(bundleID) },
            set: { hide in
                var list = settings.screenHiddenBundleIDs.filter { $0 != bundleID }
                if hide { list.append(bundleID) }
                settings.screenHiddenBundleIDs = list
            }
        )
    }

    private func reload() {
        let ownBundleID = Bundle.main.bundleIdentifier
        var entries: [String: Entry] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { continue }
            entries[bundleID] = Entry(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
        }
        for bundleID in settings.screenHiddenBundleIDs where entries[bundleID] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            entries[bundleID] = Entry(bundleID: bundleID,
                                      name: url?.deletingPathExtension().lastPathComponent ?? bundleID,
                                      icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        apps = entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
