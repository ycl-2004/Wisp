import XCTest
@testable import Wisp

/// 2026-11-20 UI/UX 审计修复的回归测试：错误行的「打开设置」、忙碌时回车、
/// 历史列表收起、空对话复用。
@MainActor
final class AuditFixes20261120Tests: XCTestCase {

    // MARK: - 错误行的「打开设置」

    func testOpenSettingsIsOfferedOnlyForErrorsFixedInsideWisp() {
        let model = AssistantModel.shared
        let saved = model.errorText
        defer { model.errorText = saved }

        for error in ProviderError.fixableInModelSettings {
            model.errorText = error.errorDescription
            XCTAssertEqual(model.errorSettingsTab, .model, "\(error)")
        }
        model.errorText = AssistantModel.voiceDisabledMessage
        XCTAssertEqual(model.errorSettingsTab, .audio)

        // 这条也带「设置」二字，但要去 macOS 系统设置处理，不该给打开 Wisp 设置的按钮。
        model.errorText = ListeningFailure.microphoneDenied.message
        XCTAssertNil(model.errorSettingsTab)
        model.errorText = ProviderError.offline.errorDescription
        XCTAssertNil(model.errorSettingsTab)
        model.errorText = nil
        XCTAssertNil(model.errorSettingsTab)
    }

    // MARK: - 忙碌时回车

    func testReturnWhileAnsweringExplainsAndKeepsTheDraft() {
        let model = AssistantModel.shared
        let saved = (model.input, model.errorText, model.isStreaming)
        defer { model.input = saved.0; model.errorText = saved.1; model.isStreaming = saved.2 }

        model.errorText = nil
        model.input = "next question"
        model.isStreaming = true
        model.send()

        XCTAssertNotNil(model.errorText, "以前这里静默返回，看起来像回车坏了")
        XCTAssertEqual(model.input, "next question")
    }

    func testReturnWithEmptyInputWhileAnsweringStaysQuiet() {
        let model = AssistantModel.shared
        let saved = (model.input, model.errorText, model.isStreaming)
        defer { model.input = saved.0; model.errorText = saved.1; model.isStreaming = saved.2 }

        model.errorText = nil
        model.input = "   "
        model.isStreaming = true
        model.send()

        XCTAssertNil(model.errorText)
    }

    // MARK: - 历史列表

    func testHidingThePanelReturnsToTheCurrentConversation() {
        let model = AssistantModel.shared
        let saved = model.showsConversationList
        defer { model.showsConversationList = saved }

        model.showsConversationList = true
        model.panelDidHide()

        XCTAssertFalse(model.showsConversationList)
    }

    // MARK: - 空对话复用

    func testBlankActiveConversationIsReusedButEphemeralAndUsedOnesAreNot() throws {
        try withStore { store, _, _ in
            XCTAssertFalse(store.activeIsBlank, "没有当前对话")

            let conversation = try XCTUnwrap(store.createNew())
            XCTAssertTrue(store.activeIsBlank)

            store.append(Message(role: .user, text: "hi"), to: conversation.id)
            XCTAssertFalse(store.activeIsBlank)

            _ = store.activateEphemeral(title: "meeting")
            XCTAssertFalse(store.activeIsBlank, "不写盘的会议对话不参与复用")
        }
    }
}
