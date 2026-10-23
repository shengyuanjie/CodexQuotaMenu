import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageNativeTurnTests: XCTestCase {
    func testNativeCreationThroughCompletionAndVisibility() throws {
        for mode in ["normal", "early_completion", "failed", "approval"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fake = root.appendingPathComponent("fake-app-server")
            let id = UUID().uuidString.lowercased()
            let script = """
            #!/usr/bin/python3
            import json,sys
            def emit(value):
                print(json.dumps(value),flush=True)
            for line in sys.stdin:
                req=json.loads(line)
                if 'id' not in req: continue
                method=req['method']
                result={}
                if method=='thread/start': result={'thread':{'id':'\(id)','source':'vscode'}}
                if method=='thread/list': result={'data':[{'id':'\(id)'}]}
                if method=='turn/start':
                    assert req['params']['threadId']=='\(id)'
                    assert req['params']['model']=='test-model'
                    assert req['params']['effort']=='low'
                    assert req['params']['input'][0]['text']=='Only reply OK'
                    result={'turn':{'id':'accepted-turn'}}
                    event={'method':'turn/completed','params':{'threadId':'\(id)','turn':{'id':'accepted-turn','status':'failed' if '\(mode)'=='failed' else 'completed'}}}
                    if '\(mode)'=='early_completion': emit(event)
                emit({'id':req['id'],'result':result})
                if method=='turn/start':
                    if '\(mode)'=='approval': emit({'id':'approval-1','method':'item/commandExecution/requestApproval','params':{}})
                    elif '\(mode)'!='early_completion':
                        emit({'method':'turn/completed','params':{'threadId':'another-thread','turn':{'id':'wrong-turn','status':'completed'}}})
                        emit(event)
            """
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let client = CodexClient(executableLocator: CodexExecutableLocator(candidatePaths: [fake.path], isExecutable: { _ in true }))
            var item = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: "", threadTitle: "New",
                model: "test-model", message: "Only reply OK", effort: "low", newTaskDirectory: root.path)
            var recorded: String?
            item.threadID = try ScheduledMessageRunner.createVisibleChat(item, directory: root,
                request: client.modelRequest, onCreated: { recorded = $0 })
            XCTAssertEqual(recorded, id)
            let result = Result { try client.completeScheduledTurn(item, directory: root, effort: "low", timeout: 2) }
            if mode == "failed" || mode == "approval" {
                XCTAssertThrowsError(try result.get()) {
                    XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, mode == "failed" ? "turn_failed" : "approval_required")
                }
            } else {
                XCTAssertTrue(try result.get())
                try ScheduledMessageRunner.verifyVisibleChat(id, directory: root, request: client.modelRequest)
            }
        }
    }
}
