import Foundation

/// Self-contained assertion runner that exercises the same logic as the
/// XCTest target. Useful for environments without full Xcode (only Command
/// Line Tools): `swift run AOPet --self-test`. CI on macos-latest with
/// Xcode should still run `swift test` for the canonical XCTest suite.
enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        func assertEqual<T: Equatable>(_ a: T, _ b: T, _ label: String, file: String = #file, line: Int = #line) {
            if a != b {
                failures.append("\(file):\(line) \(label) — expected \(b), got \(a)")
            }
        }
        func assertTrue(_ cond: Bool, _ label: String, file: String = #file, line: Int = #line) {
            if !cond {
                failures.append("\(file):\(line) \(label) — expected true")
            }
        }
        func assertNotNil<T>(_ value: T?, _ label: String, file: String = #file, line: Int = #line) {
            if value == nil {
                failures.append("\(file):\(line) \(label) — expected non-nil")
            }
        }

        // ── Wire decoding ────────────────────────────────────────────────
        do {
            let json = """
            {
              "sessions": [
                {"id":"s1","projectId":"p1","status":"working","activity":"active"},
                {"id":"s2","projectId":"p2","status":"needs_input","activity":"waiting_input"}
              ],
              "orchestrators": [
                {"id":"orc1","projectId":"p1","projectName":"First Project"},
                {"id":"orc2","projectId":"p2","projectName":"Second Project"}
              ]
            }
            """.data(using: .utf8)!
            let parsed = try WireDecoder.decodeSessions(json)
            assertEqual(parsed.sessions.count, 2, "sessions count")
            assertEqual(parsed.sessions[0].status, .working, "first status")
            assertEqual(parsed.sessions[1].activity, .waitingInput, "second activity")
            assertEqual(parsed.projectNames()["p1"], "First Project", "project name p1")
        } catch {
            failures.append("decodeSessions threw: \(error)")
        }

        do {
            let json = """
            {"sessions":[{"id":"s","projectId":"p","status":"future","activity":"novel"}],"orchestrators":[]}
            """.data(using: .utf8)!
            let parsed = try WireDecoder.decodeSessions(json)
            assertEqual(parsed.sessions.first?.status, .unknown, "unknown status")
            assertEqual(parsed.sessions.first?.activity, .unknown, "unknown activity")
        } catch {
            failures.append("tolerant decode threw: \(error)")
        }

        do {
            let line = """
            {"v":1,"kind":"event","event":{"id":"e1","type":"pr_merged","priority":"info","sessionId":"s1","projectId":"p1","timestamp":"2026-05-07T10:00:00Z","message":"PR #42 merged","data":{"pr":42}},"actions":[{"label":"Open PR","action":"open:https://example.com"}]}
            """.data(using: .utf8)!
            let env = try WireDecoder.decodeEvent(line)
            assertEqual(env.v, 1, "envelope v")
            assertEqual(env.kind, "event", "envelope kind")
            assertEqual(env.event.priority, .info, "event priority")
            assertEqual(env.event.projectId, "p1", "event projectId")
            assertEqual(env.actions?.count, 1, "actions count")
        } catch {
            failures.append("decodeEvent threw: \(error)")
        }

        do {
            let line = """
            {"v":1,"kind":"event","event":{"id":"e2","type":"system","priority":"warning","message":"dashboard restarted"}}
            """.data(using: .utf8)!
            let env = try WireDecoder.decodeEvent(line)
            assertEqual(env.event.priority, .warning, "warning priority")
            assertTrue(env.event.projectId == nil, "projectId nil when omitted")
            assertTrue(env.actions == nil, "actions nil when omitted")
        } catch {
            failures.append("optional event decode threw: \(error)")
        }

        // ── State aggregator ────────────────────────────────────────────
        func session(_ id: String, _ project: String, _ status: SessionStatus, _ activity: ActivityState? = nil) -> WireSession {
            WireSession(id: id, projectId: project, status: status, activity: activity)
        }

        assertEqual(StateAggregator.mood(for: session("s","p", .working, .waitingInput)), .alert, "waiting_input → alert")
        assertEqual(StateAggregator.mood(for: session("s","p", .needsInput, .ready)), .alert, "needs_input → alert")
        assertEqual(StateAggregator.mood(for: session("s","p", .ciFailed, .ready)), .sad, "ci_failed → sad")
        assertEqual(StateAggregator.mood(for: session("s","p", .stuck)), .sad, "stuck → sad")
        assertEqual(StateAggregator.mood(for: session("s","p", .working, .blocked)), .sad, "blocked activity → sad")
        assertEqual(StateAggregator.mood(for: session("s","p", .prOpen, .idle)), .happy, "pr_open → happy")
        assertEqual(StateAggregator.mood(for: session("s","p", .approved, .idle)), .happy, "approved → happy")
        assertEqual(StateAggregator.mood(for: session("s","p", .working, .active)), .working, "working → working")
        assertEqual(StateAggregator.mood(for: session("s","p", .idle, .idle)), .sleeping, "idle → sleeping")
        assertEqual(StateAggregator.mood(for: session("s","p", .done)), .sleeping, "done → sleeping")

        let mixed = StateAggregator.aggregate(sessions: [
            session("a","p1", .working, .active),
            session("b","p1", .prOpen, .idle),
            session("c","p1", .needsInput, .waitingInput)
        ], projectNames: ["p1": "Proj"])
        assertEqual(mixed.count, 1, "mixed grouping count")
        assertEqual(mixed[0].mood, .alert, "mixed worst-state pick")
        assertEqual(mixed[0].sessionCount, 3, "mixed session count")
        assertEqual(mixed[0].projectName, "Proj", "mixed project name")

        let twoProj = StateAggregator.aggregate(sessions: [
            session("a","p1", .working, .active),
            session("b","p1", .working, .active),
            session("c","p2", .merged)
        ], projectNames: ["p1": "Alpha", "p2": "Beta"])
        assertEqual(twoProj.count, 2, "two-project count")
        assertEqual(twoProj.map { $0.projectName }, ["Alpha", "Beta"], "two-project sort by name")
        assertEqual(twoProj[0].mood, .working, "two-project first mood")
        assertEqual(twoProj[1].mood, .sleeping, "two-project second mood")

        let fallback = StateAggregator.aggregate(
            sessions: [session("a","no-orch", .working, .active)],
            projectNames: [:]
        )
        assertEqual(fallback[0].projectName, "no-orch", "projectId fallback name")

        assertEqual(StateAggregator.aggregate(sessions: [], projectNames: [:]).count, 0, "empty input → empty")

        assertTrue(PetMood.sleeping.priority < PetMood.happy.priority, "sleeping<happy")
        assertTrue(PetMood.happy.priority < PetMood.working.priority, "happy<working")
        assertTrue(PetMood.working.priority < PetMood.sad.priority, "working<sad")
        assertTrue(PetMood.sad.priority < PetMood.alert.priority, "sad<alert")

        // ── Sprite loader (oneko) ───────────────────────────────────────
        if let oneko = SpriteLoader.load("oneko") {
            assertEqual(oneko.name, "oneko", "oneko name")
            // Canonical state → frame counts per the AO/oneko mapping.
            let expected: [(PetMood, Int)] = [
                (.sleeping, 2),
                (.working,  2),
                (.happy,    2),
                (.sad,      2),
                (.alert,    3),
            ]
            for (mood, count) in expected {
                assertEqual(
                    oneko.frameCount(for: mood),
                    count,
                    "oneko \(mood.rawValue) frame count"
                )
                for tick in 0..<count {
                    assertNotNil(
                        oneko.image(for: mood, tick: tick),
                        "oneko \(mood.rawValue) tick \(tick) image"
                    )
                }
            }
            let workingCount = oneko.frameCount(for: .working)
            let first = oneko.image(for: .working, tick: 0)
            let wrap = oneko.image(for: .working, tick: workingCount)
            let neg = oneko.image(for: .working, tick: -1)
            assertNotNil(first, "oneko working frame 0 image")
            assertNotNil(wrap, "oneko working wrapped image")
            assertNotNil(neg, "oneko working negative tick image")
        } else {
            failures.append("oneko sprite set failed to load")
        }

        assertTrue(SpriteLoader.load("does-not-exist") == nil, "missing set → nil")

        let empty = SpriteSet(name: "empty", frames: [:])
        assertTrue(empty.frameCount(for: .working) >= 1, "empty frameCount lower-bounded at 1")

        // Per-mood timing must distinguish walks from sleep — otherwise
        // walking stutters at sleep cadence.
        assertTrue(
            PetMood.working.frameDurationSeconds < PetMood.sleeping.frameDurationSeconds,
            "working < sleeping frame duration"
        )
        assertTrue(
            PetMood.alert.frameDurationSeconds < PetMood.happy.frameDurationSeconds,
            "alert < happy frame duration"
        )

        // ── Socket round-trip ───────────────────────────────────────────
        // Real bind/connect/write/read against a temp socket. This is the
        // only test that exercises SocketListener end-to-end.
        if let err = SocketTestSupport.roundTrip() {
            failures.append("socket round-trip — \(err)")
        }

        if failures.isEmpty {
            print("AOPet self-test: all assertions passed")
            return 0
        } else {
            print("AOPet self-test: \(failures.count) failure(s):")
            for f in failures { print("  - \(f)") }
            return 1
        }
    }
}
