import XCTest
@testable import CodexQuotaMenu

final class DefaultModelSettingsTests: XCTestCase {
    let desired = DefaultModelSelection(model: "gpt-6-sol", effort: "medium")
    let original = "# preserved\n[models.new_thread]\nmodel = \"gpt-6-luna\" # choice\nmodel_reasoning_effort = 'max'\nservice_tier = \"default\"\n\n[features]\nexample = true\n"

    func testEditorPreservesOtherSettingsAndComments() throws {
        let result = try ManagedModelConfig.replacing(original, with: desired)
        XCTAssertEqual(result, original.replacingOccurrences(of: "\"gpt-6-luna\"", with: "\"gpt-6-sol\"").replacingOccurrences(of: "'max'", with: "\"medium\""))
        let values = try ManagedModelConfig.values(in: result)
        XCTAssertEqual(values.model, desired.model)
        XCTAssertEqual(values.effort, desired.effort)
        XCTAssertEqual(try ManagedModelConfig.replacing(result, with: desired), result)
    }

    func testEditorAddsMissingKeyWithoutTouchingNextSection() throws {
        let text = "[models.new_thread]\nmodel = \"gpt-6-luna\"\n[other]\nmodel = \"keep\"\n"
        let result = try ManagedModelConfig.replacing(text, with: desired)
        XCTAssertTrue(result.contains("model_reasoning_effort = \"medium\""))
        XCTAssertTrue(result.contains("[other]\nmodel = \"keep\""))
    }

    func testRefusesAmbiguousOrMultilineTOML() {
        for source in ["[models.new_thread]\nmodel = \"x\"\nmodel = \"y\"\n", "[models.new_thread]\nmodel = \"x\"\n[models.new_thread]\n", "description = '''\n[models.new_thread]\n'''\n", "[\"models\".new_thread]\nmodel = \"x\""] {
            XCTAssertThrowsError(try ManagedModelConfig.replacing(source, with: desired))
        }
    }

    func testRejectsShellAndTOMLInjection() {
        for model in ["x'; touch /tmp/x; '", "x\nmodel_provider='bad'", "$(whoami)", "", "../bad"] {
            XCTAssertThrowsError(try ManagedModelConfig.replacing(original, with: .init(model: model, effort: "medium")))
        }
        XCTAssertThrowsError(try DefaultModelSelection(model: "gpt-6-sol", effort: "medium;id").validate())
        XCTAssertEqual(ManagedModelConfig.shellQuote("a'b"), "'a'\\''b'")
    }

    func testManagedDefaultsWinOnRead() throws {
        let rpc = ModelRPCStub()
        rpc.managed = ["model": "gpt-6-luna", "modelReasoningEffort": "max"]
        let snapshot = try service(rpc).load()
        XCTAssertEqual(snapshot.user, desired)
        XCTAssertEqual(snapshot.effective.model, "gpt-6-luna")
        XCTAssertEqual(snapshot.effective.effort, "max")
    }

    func testSaveUpdatesSystemThenUserAndVerifies() throws {
        let rpc = ModelRPCStub()
        rpc.managed = ["model": "gpt-6-luna", "modelReasoningEffort": "max"]
        var systemWrites = 0
        var sut = service(rpc)
        sut.readSystemFile = { self.original }
        sut.writeSystemFile = { source, selection in
            XCTAssertEqual(source, self.original)
            XCTAssertEqual(rpc.writes, 0)
            systemWrites += 1
            rpc.managed = ["model": selection.model, "modelReasoningEffort": selection.effort]
        }
        let verified = try sut.save(desired)
        XCTAssertEqual(verified.effective, desired)
        XCTAssertEqual(systemWrites, 1)
        XCTAssertEqual(rpc.writes, 1)
    }

    func testCancelAdministratorDoesNotWriteUserConfig() {
        let rpc = ModelRPCStub()
        rpc.managed = ["model": "gpt-6-luna", "modelReasoningEffort": "max"]
        var sut = service(rpc)
        sut.readSystemFile = { self.original }
        sut.writeSystemFile = { _, _ in throw DefaultModelError.administratorCancelled }
        XCTAssertThrowsError(try sut.save(desired))
        XCTAssertEqual(rpc.writes, 0)
    }

    func testExternalManagedPolicyIsNotOverwritten() {
        let rpc = ModelRPCStub()
        rpc.managed = ["model": "gpt-6-astra", "modelReasoningEffort": "high"]
        var sut = service(rpc)
        sut.readSystemFile = { self.original }
        sut.writeSystemFile = { _, _ in XCTFail("Must not request administrator access") }
        XCTAssertThrowsError(try sut.save(desired))
        XCTAssertEqual(rpc.writes, 0)
    }

    func testUserOnlySaveAndInvalidEffort() throws {
        let rpc = ModelRPCStub()
        let sut = service(rpc)
        XCTAssertEqual(try sut.save(desired).effective, desired)
        XCTAssertThrowsError(try sut.save(.init(model: "gpt-6-sol", effort: "ultra")))
        XCTAssertEqual(rpc.writes, 1)
    }

    func testMismatchAfterWriteIsReported() {
        let rpc = ModelRPCStub()
        rpc.config["model"] = "gpt-6-luna"
        rpc.ignoreWrites = true
        XCTAssertThrowsError(try service(rpc).save(desired))
    }

    func testRepeatedPaginationCursorIsRejected() {
        let rpc = ModelRPCStub()
        rpc.repeatCursor = true
        XCTAssertThrowsError(try service(rpc).load())
    }

    func testActiveProfileIsNotSilentlyChanged() {
        let rpc = ModelRPCStub()
        rpc.config["profile"] = "work"
        XCTAssertThrowsError(try service(rpc).save(desired))
        XCTAssertEqual(rpc.writes, 0)
    }

    private func service(_ rpc: ModelRPCStub) -> DefaultModelSettingsService {
        .init(makeClient: { rpc }, readSystemFile: { throw DefaultModelError.unsupportedSystemFile },
              writeSystemFile: { _, _ in XCTFail("Unexpected administrator operation") })
    }
}

private final class ModelRPCStub: DefaultModelRPC {
    var config: [String: Any] = ["model": "gpt-6-sol", "model_reasoning_effort": "medium"]
    var managed: [String: Any] = [:]
    var writes = 0
    var ignoreWrites = false
    var repeatCursor = false
    func modelRequest(_ method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "config/read": return ["config": config]
        case "configRequirements/read": return ["requirements": ["models": ["newThread": managed]]]
        case "model/list":
            var result: [String: Any] = ["data": [["model": "gpt-6-sol", "displayName": "GPT-6 Sol", "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"]]]]]
            if repeatCursor { result["nextCursor"] = "same" }
            return result
        case "config/batchWrite":
            writes += 1
            XCTAssertEqual(params["reloadUserConfig"] as? Bool, true)
            if !ignoreWrites {
                for edit in params["edits"] as? [[String: Any]] ?? [] { config[edit["keyPath"] as! String] = edit["value"] }
            }
            return ["status": "ok"]
        default: throw DefaultModelError.invalidResponse
        }
    }
}
