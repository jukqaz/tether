import SwiftUI
import UniformTypeIdentifiers
import TetherCore

/// File transfer reuses the same validated model commands as the rules editor.
/// Import remains an explicit review followed by saving inactive preset copies.
struct SettingsTransferView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showExport = false
    @State private var showImport = false
    @State private var exportDocument = SettingsExportDocument()
    @State private var importData: Data?
    @State private var importSummary: String?
    @State private var feedback: String?

    var body: some View {
        V4FeatureSheet(title: L("Import and export settings", "설정 가져오기·내보내기")) {
            Text(L("Saved app choices and automatic presets", "저장된 앱 설정과 자동 프리셋"))
                .font(TetherTypography.section).accessibilityAddTraits(.isHeader)
            Note(L("Active work, permissions and recovery records are excluded. Opening or importing a file does not start work or enable a rule.",
                   "현재 작업·권한·복구 기록은 포함하지 않습니다. 파일을 열거나 가져오기만 해서는 작업이나 규칙이 실행되지 않습니다."))
            HStack(spacing: 12) {
                Button(L("Export saved settings…", "저장된 설정 내보내기…")) {
                    guard let data = model.exportV4Settings() else {
                        feedback = L("Could not prepare an export.", "내보낼 설정을 준비하지 못했습니다."); return
                    }
                    exportDocument = SettingsExportDocument(data: data)
                    showExport = true
                }.actionButton().disabled(!canTransfer)
                    .accessibilityIdentifier("settings-transfer-export")
                Button(L("Choose settings file…", "가져올 설정 선택…")) {
                    clearImport(); feedback = nil; showImport = true
                }
                    .actionButton().disabled(!canTransfer)
                    .accessibilityIdentifier("settings-transfer-import")
            }
            if let importSummary {
                Divider()
                Text(L("Review before saving", "저장 전 검토"))
                    .font(TetherTypography.section).accessibilityAddTraits(.isHeader)
                Text(importSummary).font(TetherTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-transfer-import-review")
                Button(L("Discard this import", "이번 가져오기 취소")) { clearImport() }
                    .buttonStyle(.link).accessibilityIdentifier("settings-transfer-discard")
            }
            if let feedback {
                Note(feedback).accessibilityIdentifier("settings-transfer-feedback")
            }
            if model.userCommandsArePreview || model.developmentService {
                Note(L("File transfer is disabled in preview. No files are read or written.",
                       "미리보기에서는 설정을 가져오거나 내보내지 않습니다. 파일을 읽거나 저장하지 않습니다."))
            }
        } actions: {
            Button(L("Back", "뒤로")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("settings-transfer-back")
            Spacer()
            if importSummary != nil {
                Button(L("Save inactive copies", "비활성 복사본 저장")) {
                    guard let data = importData, model.applyV4Import(data) else {
                        feedback = model.errorText ?? L("Import failed. Nothing was applied.", "가져오지 못했습니다. 적용한 설정은 없습니다.")
                        return
                    }
                    clearImport()
                    feedback = L("Inactive copies saved. Select and confirm a copied preset separately to use it.",
                                 "자동 실행하지 않는 복사본을 저장했습니다. 사용하려면 프리셋을 별도로 선택해 확인한 뒤 적용하세요.")
                }.actionButton(prominent: true).disabled(!canTransfer)
                    .accessibilityIdentifier("settings-transfer-confirm-import")
            }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                      defaultFilename: "Tether-settings") { result in
            switch result {
            case .success: feedback = L("Saved settings exported.", "저장된 설정을 내보냈습니다.")
            case .failure(let error): feedback = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let summary = model.previewV4Import(data) else {
                    clearImport()
                    feedback = L("This settings file cannot be imported.", "이 설정 파일은 가져올 수 없습니다.")
                    return
                }
                importData = data; importSummary = summary; feedback = nil
            } catch { clearImport(); feedback = error.localizedDescription }
        }
        .accessibilityIdentifier("settings-transfer-sheet")
    }

    private var canTransfer: Bool {
        model.acceptingUserCommands && !model.commandPending && !model.userCommandsArePreview && !model.developmentService
    }
    private func clearImport() { importData = nil; importSummary = nil }
}

private struct SettingsExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
