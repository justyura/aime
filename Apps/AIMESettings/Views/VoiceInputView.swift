import AIMEVoice
import AppKit
import SwiftUI

/// 语音输入: the Right Shift dictation switch, its engine and the engine's keys.
/// Values are written for the input method (VoiceSettings); anything left empty falls
/// back to VoxBoardMac's preferences.
struct VoiceInputView: View {
    @State private var enabled = VoiceSettings.isEnabled
    @State private var engine = VoiceSettings.engine
    /// Text typed into each field, not yet saved.
    @State private var drafts: [VoiceSettings.Field: String] = [:]
    /// Bumped after a save so the "当前来源" captions re-read the store.
    @State private var revision = 0
    @State private var check: Check = .idle

    enum Check: Equatable { case idle, running, passed, failed(String) }

    var body: some View {
        Form {
            Section {
                PaneHeader(title: "语音输入", subtitle: "在任意输入框轻按右 Shift 开始说话，再按一次结束。说话时可以照常打字。",
                           symbol: "mic")
            }

            Section {
                Toggle("右 Shift 语音输入", isOn: $enabled)
                    .onChange(of: enabled) { _, on in VoiceSettings.isEnabled = on }
                Picker("识别引擎", selection: $engine) {
                    ForEach(VoiceEngineChoice.allCases) { choice in Text(choice.displayName).tag(choice) }
                }
                .onChange(of: engine) { _, choice in
                    VoiceSettings.engine = choice
                    check = .idle
                }
            }

            if !engine.fields.isEmpty {
                Section("\(engine.displayName) 凭证") {
                    ForEach(engine.fields) { field in fieldRow(field) }
                    HStack {
                        checkStatus
                        Spacer()
                        Button("测试连接", action: runCheck)
                            .disabled(check == .running || engine.fields.contains { VoiceSettings.value($0).isEmpty })
                    }
                }
            }

            Section("麦克风") {
                Label {
                    Text("第一次轻按右 Shift 时 macOS 会询问是否允许「韬输入法」使用麦克风。若当时拒绝了，或之后语音一直提示没有权限，到系统设置里打开它。开发版每次重新安装后可能需要重新允许。")
                } icon: { Image(systemName: "mic.badge.xmark").foregroundStyle(.secondary) }
                .font(.callout)
                Button("打开麦克风隐私设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }

            Section {
                Label {
                    Text("只有轻按右 Shift 之后录到的声音会发送到所选的识别服务。密钥保存在本机 ~/Library/Application Support/AIME/credentials.json（仅你的账户可读）。")
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Theme.success) }
                .font(.callout)
            }
        }
        .formStyle(.cards)
    }

    @ViewBuilder private func fieldRow(_ field: VoiceSettings.Field) -> some View {
        let _ = revision
        let binding = Binding(get: { drafts[field] ?? "" }, set: { drafts[field] = $0 })
        let draft = (drafts[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.title).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if field.isSecret {
                        SecureField("", text: binding, prompt: Text(prompt(for: field)))
                    } else {
                        TextField("", text: binding, prompt: Text(prompt(for: field)))
                    }
                }
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit { save(field) }
                Button("保存") { save(field) }.disabled(draft.isEmpty)
            }
            HStack(spacing: 8) {
                sourceCaption(field)
                if VoiceSettings.source(field) == .aime {
                    Button("清除") {
                        VoiceSettings.set(field, "")
                        revision += 1
                        check = .idle
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func prompt(for field: VoiceSettings.Field) -> String {
        switch VoiceSettings.source(field) {
        case .aime: field.isSecret ? "已保存，输入新的可替换" : VoiceSettings.ownValue(field)
        case .voxBoard: "正在使用 VoxBoardMac 的设置"
        case .missing: "未设置"
        }
    }

    @ViewBuilder private func sourceCaption(_ field: VoiceSettings.Field) -> some View {
        switch VoiceSettings.source(field) {
        case .aime: Text("已保存在韬输入法").font(.caption).foregroundStyle(Theme.success)
        case .voxBoard: Text("未单独设置，沿用 VoxBoardMac 中的值").font(.caption).foregroundStyle(.secondary)
        case .missing: Text("尚未设置").font(.caption).foregroundStyle(Theme.warning)
        }
    }

    @ViewBuilder private var checkStatus: some View {
        switch check {
        case .idle:
            Text(engine.isBatch ? "发送 1 秒静音，检查密钥与网络" : "实时引擎需在输入框里实际说一句来测试")
                .font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在测试…").foregroundStyle(.secondary) }
        case .passed:
            Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ field: VoiceSettings.Field) {
        let value = (drafts[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        VoiceSettings.set(field, value)
        drafts[field] = nil
        revision += 1
        check = .idle
    }

    private func runCheck() {
        check = .running
        VoiceSettings.testConnection(engine) { result in
            Task { @MainActor in
                switch result {
                case .success: check = .passed
                case let .failure(error): check = .failed(error.message)
                }
            }
        }
    }
}
