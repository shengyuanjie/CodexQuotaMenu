import XCTest
import AppKit
@testable import CodexQuotaMenu

final class ScheduledMessageTests: XCTestCase {
    private let threadID = "019f898f-3d2d-7a03-ab69-7a2f89882f96"

    private func item(at date: Date = Date().addingTimeInterval(3_600)) -> ScheduledMessage {
        ScheduledMessage(fireDate: date, threadID: threadID, threadTitle: "Test",
                         model: "gpt-6-sol", message: "A specific message")
    }


    func testExplicitEffortOverridesChatAndRejectsUnsupportedChoice() throws {
        let model = CodexModelOption(id: "gpt-6-sol", name: "Test", efforts: ["low", "medium", "high"], defaultEffort: "medium")
        XCTAssertEqual(try ScheduledMessageRunner.selectedEffort(option: model, requested: "high", inherited: "low"), "high")
        XCTAssertThrowsError(try ScheduledMessageRunner.selectedEffort(option: model, requested: "ultra", inherited: "low"))
        XCTAssertEqual(try ScheduledMessageRunner.selectedEffort(option: model, requested: nil, inherited: "low"), "low")
        XCTAssertEqual(try ScheduledMessageRunner.selectedEffort(option: model, requested: nil, inherited: "ultra"), "medium")
    }

    func testEffortPersistsAndOlderRecordsRemainReadable() throws {
        let message = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: threadID,
            threadTitle: "Test", model: "gpt-6-sol", message: "Hello", effort: "high")
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledMessage.self, from: data).effort, "high")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "effort")
        XCTAssertNil(try JSONDecoder().decode(ScheduledMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).effort)
        let bad = ScheduledMessage(fireDate: message.fireDate, threadID: threadID, threadTitle: "Test",
            model: "gpt-6-sol", message: "Hello", effort: "high\";bad")
        XCTAssertThrowsError(try bad.validate())
    }

    func testRunnerPassesStoredEffortInsteadOfChatEffort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let message = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: threadID,
            threadTitle: "Test", model: "gpt-6-sol", message: "Hello", effort: "high")
        try store.write(message)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { message.fireDate }
        runner.resolveThread = { _ in .init(directory: root, effort: "low") }
        runner.resolveEffort = { model, requested, inherited in
            XCTAssertEqual(model, message.model)
            XCTAssertEqual(requested, "high")
            XCTAssertEqual(inherited, "low")
            return requested!
        }
        runner.send = { _, _, effort in XCTAssertEqual(effort, "high"); return true }
        XCTAssertEqual(runner.run(id: message.id), 0)
        XCTAssertEqual(try store.read(message.id).effort, "high")
    }

    func testOwnedChatPreflightDoesNotReadCLIOrTouchProjectDirectory() throws {
        let target = try ScheduledMessageRunner.resolveTarget(id: threadID,
            readDesktop: { id in ["id": id, "cwd": "/unavailable/Documents/project", "latestReasoningEffort": "high"] },
            readCLI: { _ in XCTFail("Desktop-owned chats must not open a second backend"); throw ScheduledMessageError.missingTask },
            checkDirectory: { _ in XCTFail("Desktop delivery must not touch project files"); throw ScheduledMessageDeliveryError(code: "directory_access_denied") })
        XCTAssertEqual(target.directory.path, "/unavailable/Documents/project")
        XCTAssertEqual(target.effort, "high")
    }

    func testCLIPreflightRequiresDirectoryAccess() {
        var checked = false
        XCTAssertThrowsError(try ScheduledMessageRunner.resolveTarget(id: threadID,
            readDesktop: { _ in nil }, readCLI: { id in ["id": id, "cwd": "/protected/Documents/project"] },
            checkDirectory: { _ in checked = true; throw ScheduledMessageDeliveryError(code: "directory_access_denied") })) {
            XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "directory_access_denied")
        }
        XCTAssertTrue(checked)
    }

    func testDesktopFailureDoesNotFallBackToCLI() {
        XCTAssertThrowsError(try ScheduledMessageRunner.resolveTarget(id: threadID,
            readDesktop: { _ in throw ScheduledMessageDeliveryError(code: "desktop_connection_failed") },
            readCLI: { _ in XCTFail("Must not fall back after desktop failure"); return [:] })) {
            XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "desktop_connection_failed")
        }
    }

    func testDirectoryCheckSeparatesMissingDirectoryAndPermissionErrors() throws {
        XCTAssertEqual(ScheduledMessageRunner.directoryFailure(EPERM).code, "directory_access_denied")
        XCTAssertEqual(ScheduledMessageRunner.directoryFailure(EACCES).code, "directory_access_denied")
        let missing = URL(fileURLWithPath: "/private/tmp/cqm-missing-" + UUID().uuidString)
        XCTAssertThrowsError(try ScheduledMessageRunner.checkWorkingDirectory(missing)) {
            XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "directory_missing")
        }
        XCTAssertNoThrow(try ScheduledMessageRunner.checkWorkingDirectory(URL(fileURLWithPath: "/private/tmp")))
    }

    func testDesktopRequestKeepsExactTargetAndChosenModelEffort() {
        let entry = item()
        let request = ScheduledMessageDesktopClient.turnRequest(entry, effort: "high", directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(request["threadId"] as? String, entry.threadID)
        XCTAssertEqual(request["model"] as? String, entry.model)
        XCTAssertEqual(request["effort"] as? String, "high")
        XCTAssertEqual(request["clientUserMessageId"] as? String, entry.id.uuidString.lowercased())
        XCTAssertEqual((request["input"] as? [[String: Any]])?.first?["text"] as? String, entry.message)
        XCTAssertNil(request["approvalPolicy"])
    }

    func testDesktopSocketDeliversToExistingOwnerAndVerifiesCompletion() throws {
        let root = URL(fileURLWithPath: "/private/tmp/cqm-ipc-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("desktop.sock")
        let script = root.appendingPathComponent("server.py")
        var entry = item()
        entry.attachments = [
            .init(name: "notes.txt", path: root.appendingPathComponent("notes.txt").path, kind: .file, byteCount: 4, sha256: "fixture"),
            .init(name: "photo.png", path: root.appendingPathComponent("photo.png").path, kind: .image, byteCount: 4, sha256: "fixture")
        ]
        let source = """
        import socket,struct,json,pathlib
        root=pathlib.Path('\(root.path)')
        server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        server.bind(str(root/'desktop.sock'));server.listen(1);(root/'ready').touch()
        client,_=server.accept();started=False
        def readn(n):
            out=b''
            while len(out)<n:
                data=client.recv(n-len(out))
                if not data: raise EOFError()
                out+=data
            return out
        def send(value):
            raw=json.dumps(value).encode();client.sendall(struct.pack('<I',len(raw))+raw)
        while True:
            try: value=json.loads(readn(struct.unpack('<I',readn(4))[0]))
            except EOFError: break
            method=value['method']
            if method=='thread-stream-following-changed':
                assert value['params']['conversationId']=='\(entry.threadID)'
                send({'type':'broadcast','method':'thread-stream-state-changed','sourceClientId':'owner',
                    'params':{'conversationId':'\(entry.threadID)','change':{'type':'snapshot','conversationState':{
                        'id':'\(entry.threadID)','threadRuntimeStatus':{'type':'idle'},
                        'loadedToolHistory':'x'*21_000_000 if not started else '', 'turns':
                        [{'turnId':'native-turn','status':'completed'}] if started else []}}}})
                continue
            result={}
            if method=='initialize': result={'clientId':'client'}
            elif method=='thread-owner-discovery':
                assert value['params']['conversationId']=='\(entry.threadID)'
            elif method=='thread-follower-start-turn':
                assert not started
                assert value['targetClientId']=='owner' and value['version']==2
                request=value['params']['turnStart']['request']
                assert request['threadId']=='\(entry.threadID)' and request['model']=='gpt-6-sol' and request['effort']=='high'
                assert request['input'][0]['text'].endswith('## My request:\\nA specific message')
                assert '## notes.txt: \(root.path)/notes.txt' in request['input'][0]['text']
                assert request['input'][1]=={'type':'localImage','path':'\(root.path)/photo.png'}
                assert len(request['input'])==2
                started=True;result={'result':{'turn':{'id':'native-turn'}}};(root/'delivered').touch()
            else: raise AssertionError(method)
            send({'type':'response','requestId':value['requestId'],'resultType':'success',
                'method':method,'handledByClientId':'owner','result':result})
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]; process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let client = ScheduledMessageDesktopClient(socketURL: socket)
        XCTAssertTrue(try client.connect())
        XCTAssertEqual(try client.owner(threadID: entry.threadID), "owner")
        XCTAssertTrue(try client.deliver(entry, owner: "owner", effort: "high", directory: root, timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("delivered").path))
    }

    func testDesktopReceiveFrameLimitAllowsLongChatsButRemainsBounded() throws {
        XCTAssertNoThrow(try ScheduledMessageDesktopClient.validateReceiveFrameLength(34_952_354))
        XCTAssertNoThrow(try ScheduledMessageDesktopClient.validateReceiveFrameLength(128_000_000))
        for length: UInt32 in [0, 128_000_001, UInt32.max] {
            XCTAssertThrowsError(try ScheduledMessageDesktopClient.validateReceiveFrameLength(length)) {
                XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "desktop_frame_limit")
            }
        }
    }

    func testDesktopHistoryAndBusyStateUseCanonicalEntities() {
        let state: [String: Any] = ["threadRuntimeStatus": ["type": "active"], "turns": [],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [
                "turn:example": ["turnId": "example", "status": "completed"]],
                "islands": [["entries": [["key": "turn:example", "value": "turn:example"]]]]]]]
        XCTAssertTrue(ScheduledMessageDesktopClient.isBusy(state))
        XCTAssertEqual(ScheduledMessageDesktopClient.turns(state).first?["status"] as? String, "completed")
        var idle = state
        idle["threadRuntimeStatus"] = ["type": "idle"]
        XCTAssertFalse(ScheduledMessageDesktopClient.isBusy(idle))
    }

    func testDuplicateTaskTitlesKeepExactIDs() async {
        await MainActor.run {
            let picker = NSPopUpButton()
            let ids = ["019f898f-3d2d-7a03-ab69-7a2f89882f96", "01a0ce6c-f37f-7411-b5bd-f58b309aef1a"]
            ScheduledMessageWindowController.populateTaskMenu(picker,
                tasks: ids.map { (id: $0, title: "Same title") }, placeholder: "Choose")
            XCTAssertEqual(picker.numberOfItems, 3)
            for (index, id) in ids.enumerated() {
                picker.selectItem(at: index + 1)
                XCTAssertEqual(picker.selectedItem?.representedObject as? String, id)
            }
            ScheduledMessageWindowController.populateTaskMenu(picker,
                tasks: ids.map { (id: $0, title: String(repeating: "x", count: 80)) }, placeholder: "Choose")
            XCTAssertEqual(picker.numberOfItems, 3)
            ScheduledMessageWindowController.populateTaskMenu(picker,
                tasks: [(id: ids[0], title: "One"), (id: ids[0], title: "Duplicate"), (id: ids[1], title: "One")], placeholder: "Choose")
            XCTAssertEqual(picker.numberOfItems, 3)
            XCTAssertEqual(picker.item(at: 1)?.representedObject as? String, ids[0])
            XCTAssertEqual(picker.item(at: 2)?.representedObject as? String, ids[1])
            XCTAssertEqual(ScheduledMessageWindowController.canonicalTaskID("codex://threads/\(ids[1])?view=review"), ids[1])
        }
    }

    func testFailureDiagnosticsContainOnlyFixedCategories() {
        XCTAssertEqual(ScheduledMessageRunner.classifyFailure("error: unexpected argument '--cd'", exitCode: 2), "cli_invalid_arguments")
        XCTAssertEqual(ScheduledMessageRunner.classifyFailure("401 Unauthorized secret-data", exitCode: 1), "authentication_failed")
        XCTAssertEqual(ScheduledMessageRunner.classifyFailure("private prompt and token", exitCode: 7), "cli_exit_7")
        XCTAssertEqual(ScheduledMessageRunner.classifyFailure("CodexQuotaMenu: thread already has an active writer", exitCode: 1), "thread_writer_conflict")
        XCTAssertEqual(ScheduledMessageRunner.classifyFailure("failure in CodexQuotaMenu", exitCode: 1), "cli_exit_1")
    }

    func testValidationRejectsPastAndInvalidInput() throws {
        XCTAssertThrowsError(try item(at: Date().addingTimeInterval(-1)).validate())
        var bad = item()
        bad = ScheduledMessage(fireDate: bad.fireDate, threadID: "not-an-id", threadTitle: "Test",
                               model: "gpt-6-sol", message: "Hello")
        XCTAssertThrowsError(try bad.validate())
        bad = ScheduledMessage(fireDate: bad.fireDate, threadID: threadID, threadTitle: "Test",
                               model: "gpt-6-sol", message: "  ")
        XCTAssertThrowsError(try bad.validate())
    }

    func testPlistContainsOnlyDedicatedLabelAndRunnerArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scheduler = ScheduledMessageScheduler(store: .init(root: root), agentsDirectory: root,
            executable: URL(fileURLWithPath: "/Applications/Codex用量.app/Contents/MacOS/CodexQuotaMenu"))
        let entry = item()
        let raw = try PropertyListSerialization.propertyList(from: scheduler.plist(entry), format: nil) as! [String: Any]
        XCTAssertEqual(raw["Label"] as? String, scheduler.label(entry.id))
        XCTAssertEqual(raw["ProgramArguments"] as? [String],
            [scheduler.executable.path, "--send-scheduled-message", entry.id.uuidString])
        XCTAssertNil(raw["message"])
        XCTAssertNil(raw["threadID"])
    }

    func testSchedulingAndCancelingTouchOnlyOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agents = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let activation = agents.appendingPathComponent("com.local.codexquotamenu.activation.0430.plist")
        let original = Data("existing activation".utf8)
        try original.write(to: activation)
        let controller = RecordingMessageLaunchctl()
        let store = ScheduledMessageStore(root: root.appendingPathComponent("Messages"))
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: agents,
            executable: URL(fileURLWithPath: "/tmp/CodexQuotaMenu"), controller: controller)
        let entry = item()
        try scheduler.schedule(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scheduler.plistURL(entry.id).path))
        XCTAssertEqual(try store.read(entry.id).threadID, threadID)
        XCTAssertEqual(controller.loaded, [scheduler.label(entry.id)])
        XCTAssertEqual(try Data(contentsOf: activation), original)
        try scheduler.cancel(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scheduler.plistURL(entry.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: entry.id).path))
        XCTAssertEqual(try Data(contentsOf: activation), original)
    }

    func testBootstrapFailureRollsBackAndForeignPlistIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RecordingMessageLaunchctl()
        controller.failBootstrap = true
        let store = ScheduledMessageStore(root: root.appendingPathComponent("Messages"))
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: controller)
        let entry = item()
        XCTAssertThrowsError(try scheduler.schedule(entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: entry.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scheduler.plistURL(entry.id).path))
        try store.write(entry)
        let foreign = try PropertyListSerialization.data(fromPropertyList: ["Label": "someone.else"], format: .xml, options: 0)
        try foreign.write(to: scheduler.plistURL(entry.id))
        XCTAssertThrowsError(try scheduler.cancel(entry))
        XCTAssertEqual(try Data(contentsOf: scheduler.plistURL(entry.id)), foreign)
    }

    func testUnavailableTargetAndExpiredScheduleNeverSend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let entry = item()
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { entry.fireDate }
        runner.resolveThread = { _ in throw ScheduledMessageError.missingTask }
        runner.send = { _, _, _ in XCTFail("must not send"); return false }
        try store.write(entry)
        XCTAssertEqual(runner.run(id: entry.id), 1)
        XCTAssertEqual(try store.read(entry.id).state, .failed)
        try store.write(entry)
        runner.now = { entry.fireDate.addingTimeInterval(86_401) }
        XCTAssertEqual(runner.run(id: entry.id), 1)
        XCTAssertEqual(try store.read(entry.id).result, "missed_time")
    }

    func testRunnerSendsOnceAfterPersistingSendingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let entry = item(at: Date().addingTimeInterval(30))
        try store.write(entry)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root,
                                                   executable: URL(fileURLWithPath: "/tmp/CodexQuotaMenu"),
                                                   controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { entry.fireDate }
        runner.resolveThread = { XCTAssertEqual($0, entry.threadID); return .init(directory: root, effort: "medium") }
        runner.resolveEffort = { _, _, _ in "medium" }
        var sends = 0
        runner.send = { message, target, effort in
            sends += 1
            XCTAssertEqual(target.directory, root)
            XCTAssertEqual(effort, "medium")
            XCTAssertEqual(message.message, entry.message)
            XCTAssertEqual(try store.read(message.id).state, .sending)
            return true
        }
        XCTAssertEqual(runner.run(id: entry.id), 0)
        XCTAssertEqual(runner.run(id: entry.id), 0)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(try store.read(entry.id).state, .sent)
    }

    func testRunnerDoesNotSendEarlyOrRetryInterruptedAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let entry = item()
        try store.write(entry)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { entry.fireDate.addingTimeInterval(-1) }
        runner.send = { _, _, _ in XCTFail("should not send early"); return false }
        XCTAssertEqual(runner.run(id: entry.id), 0)
        XCTAssertEqual(try store.read(entry.id).state, .pending)
        var interrupted = entry
        interrupted.state = .sending
        try store.write(interrupted)
        XCTAssertEqual(runner.run(id: entry.id), 0)
        XCTAssertEqual(try store.read(entry.id).state, .sending)
    }

    func testTimeIsNormalizedToVisibleMinute() throws {
        let value = item(at: Date(timeIntervalSince1970: 1_800_000_059))
        XCTAssertEqual(value.fireDate.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
    }

    func testConcurrentRunnerAndStaleCancellationCannotInterruptDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let entry = item()
        try store.write(entry)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { entry.fireDate }
        runner.resolveThread = { _ in .init(directory: root, effort: nil) }
        runner.resolveEffort = { _, _, _ in "medium" }
        var other = ScheduledMessageRunner(store: store, scheduler: scheduler)
        other.now = { entry.fireDate }
        other.send = { _, _, _ in XCTFail("duplicate delivery"); return false }
        runner.send = { _, _, _ in
            XCTAssertEqual(other.run(id: entry.id), 0)
            XCTAssertThrowsError(try scheduler.cancel(entry))
            XCTAssertEqual(try store.read(entry.id).state, .sending)
            return true
        }
        XCTAssertEqual(runner.run(id: entry.id), 0)
        XCTAssertEqual(try store.read(entry.id).state, .sent)
    }

    func testRealSubprocessReceivesExactTargetModelDirectoryAndPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$PWD" > '\(root.path)/cwd'
        printf '%s\\n' "$@" > '\(root.path)/args'
        cat > '\(root.path)/prompt'
        printf '%s\\n' '{"type":"thread.started","thread_id":"\(threadID)"}' '{"type":"turn.completed"}'
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let message = item()
        XCTAssertTrue(try ScheduledMessageRunner.runCodex(message, directory: root, effort: "medium", executable: fake, timeout: 5))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prompt")), message.message)
        let actualDirectory = try String(contentsOf: root.appendingPathComponent("cwd")).trimmingCharacters(in: .newlines)
        XCTAssertEqual(URL(fileURLWithPath: actualDirectory).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        let args = try String(contentsOf: root.appendingPathComponent("args")).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["exec", "--cd", root.path, "--skip-git-repo-check", "resume", "--all", "--json",
                              "--model", message.model, "--config", "model_reasoning_effort=\"medium\"", message.threadID, "-"])
    }

    func testSubprocessFailurePreservesRedactedReasonInRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let entry = item()
        try store.write(entry)
        let fake = root.appendingPathComponent("failed-codex")
        try "#!/bin/sh\nprintf '%s\\n' '401 Unauthorized secret-token private-prompt' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: RecordingMessageLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { entry.fireDate }
        runner.resolveThread = { _ in .init(directory: root, effort: "medium") }
        runner.resolveEffort = { _, _, _ in "medium" }
        runner.send = { message, target, effort in
            try ScheduledMessageRunner.runCodex(message, directory: target.directory, effort: effort, executable: fake, timeout: 5)
        }
        XCTAssertEqual(runner.run(id: entry.id), 1)
        let saved = try store.read(entry.id)
        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(saved.result, "authentication_failed")
        XCTAssertFalse(try String(contentsOf: store.url(for: entry.id)).contains("secret-token"))
    }

    func testCompletionForDifferentThreadIsNotReportedAsSent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("wrong-thread")
        try "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"wrong-id\"}' '{\"type\":\"turn.completed\"}'\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        XCTAssertThrowsError(try ScheduledMessageRunner.runCodex(item(), directory: root, effort: "medium", executable: fake, timeout: 5))
        XCTAssertThrowsError(try ScheduledMessageRunner.runCodex(item(), directory: root, effort: "medium", executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: 5))
    }
}

private final class RecordingMessageLaunchctl: LaunchctlControlling {
    var loaded = Set<String>()
    var failBootstrap = false
    func bootstrap(plistURL: URL) throws {
        if failBootstrap { throw ScheduledMessageError.commandFailed }
        loaded.insert(plistURL.deletingPathExtension().lastPathComponent)
    }
    func isLoaded(label: String) throws -> Bool { loaded.contains(label) }
    func loadedOwnedLabels() throws -> Set<String> { loaded }
    func bootout(label: String) throws { loaded.remove(label) }
}
