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
        assertEqual(StateAggregator.mood(for: session("s","p", .reviewPending, .idle)), .happy, "review_pending → happy")
        assertEqual(StateAggregator.mood(for: session("s","p", .approved, .idle)), .happy, "approved → happy")
        assertEqual(StateAggregator.mood(for: session("s","p", .merged, .idle)), .happy, "merged → happy")
        assertEqual(StateAggregator.mood(for: session("s","p", .working, .active)), .working, "working → working")
        assertEqual(StateAggregator.mood(for: session("s","p", .idle, .idle)), .sleeping, "idle → sleeping")
        assertEqual(StateAggregator.mood(for: session("s","p", .done)), .sleeping, "done → sleeping")

        // ── Global aggregator ────────────────────────────────────────────
        // The pet is one global window now — every session collapses to
        // one InstanceState whose mood is the worst across all projects.
        let emptyState = StateAggregator.aggregateGlobal(sessions: [])
        assertEqual(emptyState.mood, .hidden, "empty global mood")
        assertEqual(emptyState.totalSessions, 0, "empty global totalSessions")
        assertTrue(emptyState.hasSessions == false, "empty global hasSessions=false")

        let threeProjects = StateAggregator.aggregateGlobal(sessions: [
            session("a","p1", .working, .active),
            session("b","p2", .prOpen, .idle),
            session("c","p3", .ciFailed, .ready),
            session("d","p1", .needsInput, .waitingInput),
        ])
        assertEqual(threeProjects.mood, .alert, "3-project worst-state pick")
        assertEqual(threeProjects.totalSessions, 4, "3-project total session count")

        let allIdle = StateAggregator.aggregateGlobal(sessions: [
            session("a","p1", .idle, .idle),
            session("b","p2", .done),
            session("c","p3", .done),
        ])
        assertEqual(allIdle.mood, .sleeping, "all-idle global mood")
        assertEqual(allIdle.totalSessions, 3, "all-idle total")

        // ── Bubble priority filter ──────────────────────────────────────
        // Only urgent + action surface a bubble. Routine warning/info
        // chatter is silently dropped — no bubble, no animation.
        assertTrue(PetController.shouldShowBubble(for: .urgent),  "bubble: urgent shows")
        assertTrue(PetController.shouldShowBubble(for: .action),  "bubble: action shows")
        assertTrue(!PetController.shouldShowBubble(for: .warning), "bubble: warning hidden")
        assertTrue(!PetController.shouldShowBubble(for: .info),    "bubble: info hidden")
        assertTrue(!PetController.shouldShowBubble(for: .unknown), "bubble: unknown hidden")

        // ── Bubble sound mapping ────────────────────────────────────────
        // Urgent → Sosumi (classic attention chime); action → Glass
        // (softer, positive). Other priorities are silent.
        assertEqual(PetController.soundName(for: .urgent), "Sosumi", "sound: urgent → Sosumi")
        assertEqual(PetController.soundName(for: .action), "Glass",  "sound: action → Glass")
        assertTrue(PetController.soundName(for: .warning) == nil,    "sound: warning silent")
        assertTrue(PetController.soundName(for: .info)    == nil,    "sound: info silent")
        assertTrue(PetController.soundName(for: .unknown) == nil,    "sound: unknown silent")

        // ── Bubble text format ──────────────────────────────────────────
        // Format is `<projectName> <sessionId> <message>` — space
        // separated, no brackets. The message is the only piece that
        // gets truncated; identifiers always survive.
        assertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: nil,
                sessionId: nil
            ),
            "PR #5 opened",
            "bubble: nil project + session"
        )
        assertEqual(
            PetController.bubbleText(
                message: "needs your approval",
                projectName: "agent-orchestrator",
                sessionId: "ao-170"
            ),
            "agent-orchestrator ao-170 needs your approval",
            "bubble: project + session + message"
        )
        assertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: "ao",
                sessionId: nil
            ),
            "ao PR #5 opened",
            "bubble: project only"
        )
        assertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: nil,
                sessionId: "ao-170"
            ),
            "ao-170 PR #5 opened",
            "bubble: session only"
        )
        // Realistic-length messages now round-trip in full — the
        // bubble wraps visually instead of pre-truncating.
        let normalMessage = "Session ao-170 needs your approval to merge the pull request"
        let normalResult = PetController.bubbleText(
            message: normalMessage,
            projectName: "agent-orchestrator",
            sessionId: "ao-170"
        )
        assertEqual(
            normalResult,
            "agent-orchestrator ao-170 \(normalMessage)",
            "bubble: normal message preserved in full"
        )

        // Pathologically long messages still get truncated — that's
        // the runaway-input guard, not the visual cut.
        let runaway = String(repeating: "x", count: 1000)
        let truncated = PetController.bubbleText(
            message: runaway,
            projectName: "agent-orchestrator",
            sessionId: "ao-170"
        )
        assertTrue(
            truncated.hasPrefix("agent-orchestrator ao-170 "),
            "bubble: identifiers survive runaway truncation"
        )
        assertTrue(truncated.hasSuffix("…"), "bubble: runaway truncated with ellipsis")
        assertTrue(truncated.count <= 250, "bubble: runaway within budget")

        // ── Bubble auto-grow ────────────────────────────────────────────
        // ThoughtBubbleView measures wrapped text height; PetView
        // clamps to [min, max] and tells the controller to resize the
        // window upward.
        do {
            let bubble = ThoughtBubbleView(frame: NSRect(x: 0, y: 0, width: 224, height: 52))
            bubble.text = "PR #5 opened"
            let h = bubble.preferredHeight(forWidth: 224)
            assertTrue(h > 0,                                   "preferredHeight: short non-zero")
            assertTrue(h <= PetView.minBubbleHeight,            "preferredHeight: short ≤ min")

            bubble.text = String(repeating: "wrap me ", count: 30)
            let bigH = bubble.preferredHeight(forWidth: 224)
            assertTrue(bigH > PetView.minBubbleHeight,          "preferredHeight: long > min")

            let huge = String(repeating: "x ", count: 5000)
            let (clamped, total) = PetView.preferredSize(forText: huge, bubble: bubble)
            assertEqual(clamped, PetView.maxBubbleHeight,       "preferredSize: clamp at max")
            assertEqual(
                total.height,
                PetView.maxBubbleHeight + 64 + 16,
                "preferredSize: total uses max + sprite + margins"
            )

            let (minBH, minTotal) = PetView.preferredSize(forText: "hi", bubble: bubble)
            assertEqual(minBH, PetView.minBubbleHeight, "preferredSize: short = min")
            assertEqual(minTotal, PetView.totalSize,    "preferredSize: short = totalSize")
        }

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

        // ── Window drag opt-in ──────────────────────────────────────────
        // The pet window is borderless; isMovableByWindowBackground only
        // works if subviews opt in to mouseDown forwarding. Both PetView
        // and the sprite NSImageView subclass must return true here.
        let dragView = PetView(frame: NSRect(origin: .zero, size: PetView.totalSize))
        assertTrue(dragView.mouseDownCanMoveWindow, "PetView.mouseDownCanMoveWindow = true")
        let dragSprite = DraggableImageView(frame: .zero)
        assertTrue(dragSprite.mouseDownCanMoveWindow, "DraggableImageView.mouseDownCanMoveWindow = true")

        // ── Socket round-trip ───────────────────────────────────────────
        // Real bind/connect/write/read against a temp socket. This is the
        // only test that exercises SocketListener end-to-end.
        if let err = SocketTestSupport.roundTrip() {
            failures.append("socket round-trip — \(err)")
        }

        // ── MoodScheduler distribution + idle override ──────────────────
        // Random idle rotation: 50/30/20 weights for sleeping/happy/working.
        assertEqual(MoodScheduler.weightedMood(roll: 0.00),  .sleeping, "weighted: 0.00 → sleeping")
        assertEqual(MoodScheduler.weightedMood(roll: 0.49),  .sleeping, "weighted: 0.49 → sleeping")
        assertEqual(MoodScheduler.weightedMood(roll: 0.50),  .happy,    "weighted: 0.50 → happy")
        assertEqual(MoodScheduler.weightedMood(roll: 0.79),  .happy,    "weighted: 0.79 → happy")
        assertEqual(MoodScheduler.weightedMood(roll: 0.80),  .working,  "weighted: 0.80 → working")
        assertEqual(MoodScheduler.weightedMood(roll: 0.999), .working,  "weighted: 0.999 → working")

        // The random pool MUST exclude attention/event moods.
        for i in 0..<1000 {
            let roll = Double(i) / 1000.0
            let mood = MoodScheduler.weightedMood(roll: roll)
            assertTrue(mood != .alert,  "weighted: never alert  (roll=\(roll))")
            assertTrue(mood != .sad,    "weighted: never sad    (roll=\(roll))")
            assertTrue(mood != .hidden, "weighted: never hidden (roll=\(roll))")
        }

        // Idle override at 5min forces sleeping regardless of roll.
        let idleSched = MoodScheduler(
            pickRoll: { 0.95 },
            pickInterval: { 30 },
            idleProvider: { 350 },
            onTick: { _ in }
        )
        assertEqual(idleSched.pickMood(), .sleeping, "idle ≥ 300 → forced sleeping")
        assertEqual(MoodScheduler.forceSleepIdleSeconds, 300, "forceSleepIdleSeconds = 300")

        // Just below threshold honours the random roll.
        let activeSched = MoodScheduler(
            pickRoll: { 0.95 },
            pickInterval: { 30 },
            idleProvider: { 299 },
            onTick: { _ in }
        )
        assertEqual(activeSched.pickMood(), .working, "idle < 300 → random pick")

        // ── Switch-sprite cycle ─────────────────────────────────────────
        // Two real animals (oneko cat MIT + dog public-domain XBM).
        // cycleSprite rotates through them and persists each pick to
        // the supplied UserDefaults.
        assertEqual(SpriteLoader.availableSets, ["oneko", "dog"], "availableSets")
        let suite = "AOPetSelfTest.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { testDefaults.removePersistentDomain(forName: suite) }
        let manager = WindowManager(defaults: testDefaults)
        assertEqual(manager.currentSpriteName, "oneko", "cycle: starts at oneko")
        let s1 = manager.cycleSprite()
        assertEqual(s1, "dog", "cycle: oneko → dog")
        let s2 = manager.cycleSprite()
        assertEqual(s2, "oneko", "cycle: dog → oneko")
        assertEqual(testDefaults.string(forKey: "pet.spriteSet"), "oneko", "cycle: persisted")

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
