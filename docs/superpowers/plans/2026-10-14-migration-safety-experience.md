# Migration Safety Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn every application-migration entry point into a reviewable, phase-aware safety flow with the approved calm-control visual language.

**Architecture:** Keep `AppMigrator` as the sole owner of filesystem mutation, rollback, journaling and execution-time validation. Add a pure presentation model that turns a selected app set plus `DriveInfo` into a plan-review state, a sheet that displays and confirms that state, and focused execution/result views that consume the existing `MigrationTask` and `MigrationResult` data. Store the pending review request in `AppState` so the migration page and app-list selection use one sheet and one confirmation path.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager; macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-14-migration-safety-experience-design.md`

## Global Constraints

- Do not alter `AppMigrator` copy, link, backup, rollback, cancellation-token or `OperationJournal` semantics.
- A migration must not start until the user sees a plan and clicks one explicit “确认并开始” action.
- The execution flow must continue to re-run existing service-side safeguards because a disk or app can change after review.
- Use the existing single accent `MockTheme.accent`; success, warning and blocking states must include both icon and text.
- Use monospaced digits for bytes, percentages and time-like numeric values; respect `accessibilityReduceMotion`.
- Do not add dependencies, networking, telemetry or license changes.

## Review Focus

- No external disk: the review state must be blocked and must never render the confirmation button.
- Insufficient destination space: plan review must name the two-copy backup budget and prevent execution.
- A selected app stops being migratable after scan: confirmation must re-check the selected items before calling `AppMigrator`.
- Cancellation after execution starts: result copy must distinguish cancellation from failure and never claim migration completed.
- Mixed batch outcomes: completed items, the interrupted item and unstarted items must be reported without hiding a failure.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/Suishouqian/Views/MigrationPlanPresentation.swift` | Pure value types and factory for plan review, stage labels and result copy; has no SwiftUI side effects. |
| `Sources/Suishouqian/Views/MigrationPlanReviewSheet.swift` | Calm-control review sheet that renders an executable or blocked plan and yields one confirmation callback. |
| `Sources/Suishouqian/Views/MigrationExecutionView.swift` | Phase timeline plus explicit running, succeeded, cancelled and failed result surfaces. |
| `Sources/Suishouqian/Views/MigrationPanel.swift` | Owns batching coordinator and maps existing migration calls into presentation results. |
| `Sources/Suishouqian/Views/AppListView.swift` | Routes selected normal apps into the common migration-plan request instead of directly mutating files. |
| `Sources/Suishouqian/ContentView.swift` | Presents the single app-wide plan sheet from `AppState`. |
| `Sources/Suishouqian/App.swift` | Adds the pending request and current presentation result to `AppState`. |
| `Sources/Suishouqian/Views/Design.swift` | Adds small reusable stage and result visual primitives that use the existing theme. |
| `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift` | Covers pure plan, phase and outcome mapping. |

### Task 1: Build the pure migration-plan and outcome presentation model

**Files:**
- Create: `Sources/Suishouqian/Views/MigrationPlanPresentation.swift`
- Create: `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

**Interfaces:**
- Consumes: `AppItem`, `DriveInfo`, `AppMigrator.requiredTargetBytes(appSize:)`, `MigrationTask.TaskStatus`, and `AppMigrator.MigrationResult`.
- Produces: `MigrationPlanRequest`, `MigrationPlanState`, `MigrationPlanItem`, `MigrationExecutionPhase`, and `MigrationOutcome` for Tasks 2–4.

- [ ] **Step 1: Write failing plan-state tests**

```swift
func testMissingExternalDriveBlocksPlan() {
    let state = MigrationPlanPresentation.makePlan(
        apps: [app(name: "Xcode", size: 15 * gb)], drive: nil)
    XCTAssertEqual(state, .blocked(reasons: ["未检测到外置硬盘，插入后自动识别"]))
}

func testInsufficientSpaceNamesTwoCopyBudget() {
    let state = MigrationPlanPresentation.makePlan(
        apps: [app(name: "Xcode", size: 10 * gb)],
        drive: drive(freeSize: 20 * gb))
    guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
    XCTAssertTrue(reasons.joined().contains("两份空间"))
}

func testReadyPlanUsesExistingNoLinkPreference() {
    var storeApp = app(name: "Store", size: gb)
    storeApp.updateMechanism = .appStore
    guard case .ready(let plan) = MigrationPlanPresentation.makePlan(
        apps: [storeApp], drive: drive(freeSize: 10 * gb)) else { return XCTFail("expected ready") }
    XCTAssertFalse(plan.items[0].createsLink)
}
```

- [ ] **Step 2: Run the focused test target and verify compilation fails**

Run: `swift test --filter MigrationPlanPresentationTests`

Expected: FAIL because `MigrationPlanPresentation` and the plan types do not exist.

- [ ] **Step 3: Define the value-only interfaces and minimal factory**

```swift
struct MigrationPlanRequest: Identifiable {
    let id = UUID()
    let apps: [AppItem]
}

enum MigrationPlanState: Equatable {
    case blocked(reasons: [String])
    case ready(MigrationPlanSummary)
}

struct MigrationPlanSummary: Equatable {
    let id = UUID()
    let destinationName: String
    let destinationPath: String
    let freeBytes: Int64
    let requiredBytes: Int64
    let totalFreedBytes: Int64
    let items: [MigrationPlanItem]
}

struct MigrationPlanItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let size: Int64
    let sourcePath: String
    let createsLink: Bool
}

enum MigrationPlanPresentation {
    static func makePlan(apps: [AppItem], drive: DriveInfo?) -> MigrationPlanState {
        guard let drive else {
            return .blocked(reasons: [VolumeOfflineBanner.message(for: nil)])
        }
        guard !apps.isEmpty else {
            return .blocked(reasons: ["没有可迁移的应用"])
        }
        let invalid = apps.filter { $0.status != .normal }
        guard invalid.isEmpty else {
            return .blocked(reasons: invalid.map { "「\($0.name)」当前不可迁移" })
        }
        let required = apps.reduce(Int64(0)) {
            $0 + AppMigrator.requiredTargetBytes(appSize: $1.size)
        }
        guard drive.freeSize >= required else {
            return .blocked(reasons: ["外置盘剩余空间不足以容纳两份空间（副本与备份）"])
        }
        return .ready(MigrationPlanSummary(
            destinationName: drive.name, destinationPath: drive.mountPoint,
            freeBytes: drive.freeSize, requiredBytes: required,
            totalFreedBytes: apps.reduce(0) { $0 + $1.size },
            items: apps.map { MigrationPlanItem(
                id: $0.id, name: $0.name, size: $0.size, sourcePath: $0.path,
                createsLink: !$0.updateMechanism.prefersNoLink) }))
    }
}
```

Implement `makePlan` with these exact rules: no drive returns the shared `VolumeOfflineBanner.message(for: nil)` reason; an empty app set returns `"没有可迁移的应用"`; every non-`.normal` app is named in a blocking reason; `requiredBytes` is the sum of `AppMigrator.requiredTargetBytes(appSize:)`; destination capacity below that sum returns a reason containing `"两份空间"`; otherwise return `.ready` and set `createsLink` to `!app.updateMechanism.prefersNoLink`.

- [ ] **Step 4: Add phase and outcome mappings with tests**

```swift
func testCancelledOutcomeNeverUsesSuccessCopy() {
    let outcome = MigrationPlanPresentation.outcome(
        result: .init(success: false, error: "已取消", spaceSaved: 0, cancelled: true),
        appName: "Xcode")
    XCTAssertEqual(outcome.title, "迁移已安全取消")
    XCTAssertTrue(outcome.detail.contains("源应用未动"))
}

func testFailedStatusMapsToBlockedPhase() {
    XCTAssertEqual(MigrationExecutionPhase(status: .failed("磁盘已断开")), .blocked)
}
```

Define `MigrationExecutionPhase` as `.preflight`, `.backup`, `.copyAndSwitch`, `.verify`, `.blocked`, and define `MigrationOutcome` with `kind`, `title`, `detail`, `spaceSaved`. Map `.preparing` to `.preflight`, `.copying`/`.linking` to `.copyAndSwitch`, `.verifying` to `.verify`, `.completed` to `.verify`, `.cancelled` and `.failed` to `.blocked`. The cancelled detail must state that the source app is untouched and the partial destination copy was cleaned; the failure detail must include the service-provided error without claiming rollback succeeded.

- [ ] **Step 5: Run presentation tests and the model-adjacent regression tests**

Run: `swift test --filter MigrationPlanPresentationTests && swift test --filter CancellationTests && swift test --filter MigrationPlannerTests`

Expected: PASS. The existing cancellation and planning behavior remains unchanged.

- [ ] **Step 6: Commit the isolated model change**

```bash
git add Sources/Suishouqian/Views/MigrationPlanPresentation.swift Tests/SuishouqianTests/MigrationPlanPresentationTests.swift
git commit -m "feat: model migration plan presentation"
```

### Task 2: Build the plan-review sheet and shared calm-control components

**Files:**
- Create: `Sources/Suishouqian/Views/MigrationPlanReviewSheet.swift`
- Modify: `Sources/Suishouqian/Views/Design.swift`
- Test: `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

**Interfaces:**
- Consumes: `MigrationPlanRequest`, `MigrationPlanState`, and `MigrationPlanPresentation.makePlan(apps:drive:)` from Task 1.
- Produces: `MigrationPlanReviewSheet(request:onConfirm:)`, where `onConfirm` receives `MigrationPlanSummary`.

- [ ] **Step 1: Add a failing plan review contract test**

```swift
func testBlockedStateContainsNoExecutableSummary() {
    let state = MigrationPlanPresentation.makePlan(
        apps: [app(name: "Xcode", size: gb)], drive: nil)
    guard case .blocked = state else { return XCTFail("expected blocked") }
    XCTAssertNil(state.summary)
}
```

Add a read-only `var summary: MigrationPlanSummary?` extension on `MigrationPlanState` that returns a summary only for `.ready`.

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter MigrationPlanPresentationTests/testBlockedStateContainsNoExecutableSummary`

Expected: FAIL because `summary` has not been implemented.

- [ ] **Step 3: Implement reusable visual primitives and the sheet**

```swift
struct MigrationStageNode: View {
    let title: String
    let state: MigrationStageVisualState
}

struct MigrationPlanReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    let request: MigrationPlanRequest
    let onConfirm: (MigrationPlanSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = MigrationPlanPresentation.makePlan(
            apps: request.apps, drive: appState.externalDrive)
        // render .blocked reasons or .ready summary; only .ready renders confirmation
    }
}
```

Use a 620–680 point wide sheet. In `.ready`, show destination name/path, free bytes, total release bytes, required two-copy budget, each item’s name/size/source/link policy, and the four fixed stages. Render only one primary button labelled `确认并开始`; it calls `onConfirm(summary)` then dismisses. In `.blocked`, render the warning icon, all reasons, a `关闭` button, and no primary action. Style cards using the existing `MockTheme.accent`, `StatusPill`, `.monospacedDigit()`, `Theme.Corner.card`, and reduce-motion-safe transitions.

- [ ] **Step 4: Run the focused test and package build**

Run: `swift test --filter MigrationPlanPresentationTests && swift build`

Expected: PASS; the new sheet compiles without adding a package dependency.

- [ ] **Step 5: Commit the review surface**

```bash
git add Sources/Suishouqian/Views/MigrationPlanReviewSheet.swift Sources/Suishouqian/Views/Design.swift Tests/SuishouqianTests/MigrationPlanPresentationTests.swift
git commit -m "feat: add migration plan review sheet"
```

### Task 3: Add phase-aware execution and terminal result presentation

**Files:**
- Create: `Sources/Suishouqian/Views/MigrationExecutionView.swift`
- Modify: `Sources/Suishouqian/Views/MigrationPanel.swift`
- Test: `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

**Interfaces:**
- Consumes: `MigrationTask`, `MigrationExecutionPhase(status:)`, `MigrationOutcome`, and `MigrationStageNode` from Tasks 1–2.
- Produces: `MigrationExecutionView(task:outcome:onOpenApps:onShowHistory:)` for the panel’s running and terminal areas.

- [ ] **Step 1: Add failing terminal-outcome tests**

```swift
func testSuccessfulOutcomeReportsFreedSpace() {
    let outcome = MigrationPlanPresentation.outcome(
        result: .init(success: true, spaceSaved: 1_073_741_824), appName: "Xcode")
    XCTAssertEqual(outcome.kind, .success)
    XCTAssertTrue(outcome.detail.contains("1 GB"))
}

func testFailureOutcomePreservesServiceError() {
    let outcome = MigrationPlanPresentation.outcome(
        result: .init(success: false, error: "目标盘已断开"), appName: "Xcode")
    XCTAssertEqual(outcome.kind, .failure)
    XCTAssertTrue(outcome.detail.contains("目标盘已断开"))
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter MigrationPlanPresentationTests/testSuccessfulOutcomeReportsFreedSpace`

Expected: FAIL until the successful-result branch is implemented.

- [ ] **Step 3: Implement result mapping and execution view**

```swift
struct MigrationExecutionView: View {
    let task: MigrationTask?
    let outcome: MigrationOutcome?
    let onOpenApps: () -> Void
    let onShowHistory: () -> Void
}
```

When `task` is nonterminal, render the four nodes in the fixed order, highlight the node derived from `task.status`, show `task.currentFile`, monospaced `Int(task.progress * 100)%`, and a text-style `取消迁移` control. That control calls `task.cancellationToken.cancel()` and changes its own nearby copy to `正在安全停止，等待清理完成…`; it does not clear `appState.migrationTask`. When `outcome.kind == .success`, show `已释放` plus formatted `spaceSaved`, then `查看应用` and `迁移历史`. When cancelled, display the mandatory source/partial-copy safety detail and only `迁移历史`. When failed, display the service error, `迁移历史`, and a non-destructive `关闭` action. Do not show a terminal success state until the existing migrator call returns `success == true`.

- [ ] **Step 4: Replace the panel’s current task card with the execution view**

Keep `MigrationPanel.taskCard` only if it can delegate entirely to `MigrationExecutionView`; otherwise remove it. Add `@State private var lastOutcome: MigrationOutcome?`, clear it when a new execution starts, and set it from each actual `MigrationResult` before clearing `appState.migrationTask`. Preserve `batchSummary` for multi-item aggregation, but include failed/cancelled individual outcomes in the new view.

- [ ] **Step 5: Run focused and safety regression tests**

Run: `swift test --filter MigrationPlanPresentationTests && swift test --filter CancellationTests && swift test --filter RegressionFixTests`

Expected: PASS. Cancellation remains a terminal non-failure, and regression tests keep their existing results.

- [ ] **Step 6: Commit execution feedback**

```bash
git add Sources/Suishouqian/Views/MigrationExecutionView.swift Sources/Suishouqian/Views/MigrationPanel.swift Tests/SuishouqianTests/MigrationPlanPresentationTests.swift
git commit -m "feat: show migration phases and outcomes"
```

### Task 4: Route every migration entry through one reviewed request and execute safely

**Files:**
- Modify: `Sources/Suishouqian/App.swift`
- Modify: `Sources/Suishouqian/ContentView.swift`
- Modify: `Sources/Suishouqian/Views/MigrationPanel.swift`
- Modify: `Sources/Suishouqian/Views/AppListView.swift`
- Test: `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

**Interfaces:**
- Consumes: `MigrationPlanRequest`, `MigrationPlanSummary`, `MigrationPlanReviewSheet`, and `MigrationExecutionView` from Tasks 1–3.
- Produces: `AppState.migrationPlanRequest` as the only UI route that starts a normal application migration.

- [ ] **Step 1: Add failing request-to-plan coverage**

```swift
func testNonNormalSelectedAppBlocksBeforeExecution() {
    var migrated = app(name: "Moved", size: gb)
    migrated.status = .migrated
    let state = MigrationPlanPresentation.makePlan(
        apps: [migrated], drive: drive(freeSize: 10 * gb))
    guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
    XCTAssertTrue(reasons.joined().contains("不可迁移"))
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter MigrationPlanPresentationTests/testNonNormalSelectedAppBlocksBeforeExecution`

Expected: FAIL until `makePlan` checks `AppItem.status`.

- [ ] **Step 3: Add the shared request state and global sheet**

```swift
// AppState in App.swift
@Published var migrationPlanRequest: MigrationPlanRequest?

// ContentView detail container
.sheet(item: $appState.migrationPlanRequest) { request in
    MigrationPlanReviewSheet(request: request) { summary in
        appState.migrationPlanRequest = nil
        appState.approvedMigrationPlan = summary
        appState.activePanel = .migrate
    }
    .environmentObject(appState)
}
```

Add `@Published var approvedMigrationPlan: MigrationPlanSummary?` beside `migrationPlanRequest` in `AppState`. In `MigrationPanel`, observe `approvedMigrationPlan?.id` and also call the same consumer from `onAppear`; `consumeApprovedPlan()` must take the value, set `approvedMigrationPlan = nil`, and call `executeReviewedPlan(_:)` exactly once. Before the first `AppMigrator.migrate` call, derive fresh candidates from `apps` by matching each `MigrationPlanItem.id`; if any no longer exists or is no longer `.normal`, set a blocked `MigrationOutcome` and return without mutation. Preserve execution-time service validation by passing each selected `AppItem` to the existing `migrator.migrate` call unchanged.

- [ ] **Step 4: Replace direct migration starts at all normal-app entry points**

In `MigrationPanel`, replace `migrateAll()`’s direct loop with construction of `MigrationPlanRequest(apps: targets)` after the existing `MigrationAdvisor.resolveBatch` decision. In `AppListView.runSelected(migrate: true)`, set `appState.migrationPlanRequest = MigrationPlanRequest(apps: targets)` and return; retain the existing direct restore path for `migrate == false`. In any single-app migration action in `AppRowView`, set the same request rather than calling `AppMigrator.migrate`. Do not route restore, uninstall, relocation or disk-retirement flows through this new sheet.

- [ ] **Step 5: Update the execution coordinator to use reviewed summaries**

Move or expose the existing serial execution loop as `MigrationPanel.executeReviewedPlan(_ summary: MigrationPlanSummary)`. For each summary item, find its fresh `AppItem` by UUID, create `MigrationTask`, pass the existing cancellation token to `migrator.migrate`, report progress through `appState.reportMigrationProgress`, map the returned result to `lastOutcome`, and call `await appState.scanApps()` after terminal completion. On cancellation, break the batch; on ordinary failure, record it and continue remaining entries exactly as the existing batch behavior does.

- [ ] **Step 6: Run the complete test suite and build**

Run: `swift test && swift build -c release`

Expected: PASS with all existing tests plus `MigrationPlanPresentationTests`; no warning or error about Swift concurrency isolation.

- [ ] **Step 7: Manual acceptance check**

Run the app and verify these exact cases:

1. With no external drive, click a normal-app migration entry: the sheet names the missing drive and has no `确认并开始` button.
2. With an external drive that cannot fit `AppMigrator.requiredTargetBytes`, the sheet says the two-copy budget is insufficient and cannot start.
3. With a valid external drive, review a plan, confirm it, cancel during copying, and verify the result says the source is untouched and partial copy cleanup completed.
4. Complete a small test-app migration and verify the result shows actual released space plus application-list and history exits.

- [ ] **Step 8: Commit integrated safety flow**

```bash
git add Sources/Suishouqian/App.swift Sources/Suishouqian/ContentView.swift Sources/Suishouqian/Views/MigrationPanel.swift Sources/Suishouqian/Views/AppListView.swift Sources/Suishouqian/Views/AppRowView.swift Tests/SuishouqianTests/MigrationPlanPresentationTests.swift
git commit -m "feat: require reviewed migration plans"
```

### Task 5: Apply the calm-control visual refinement across existing navigation and migration entry surfaces

**Files:**
- Modify: `Sources/Suishouqian/ContentView.swift`
- Modify: `Sources/Suishouqian/Views/MigrationPanel.swift`
- Modify: `Sources/Suishouqian/Views/AppListView.swift`
- Modify: `Sources/Suishouqian/Views/Design.swift`
- Test: `Tests/SuishouqianTests/MigrationPlanPresentationTests.swift`

**Interfaces:**
- Consumes: the reviewed-plan route from Task 4 and shared stage/result primitives from Tasks 2–3.
- Produces: a consistent visual hierarchy for navigation, primary migration action, supporting actions, and safety status.

- [ ] **Step 1: Add a visual-state data test for numeric and accessibility copy**

```swift
func testReadyPlanSummaryRetainsExactByteValuesForMonospacedRendering() {
    guard case .ready(let summary) = MigrationPlanPresentation.makePlan(
        apps: [app(name: "Xcode", size: gb)], drive: drive(freeSize: 10 * gb)) else {
        return XCTFail("expected ready")
    }
    XCTAssertEqual(summary.totalFreedBytes, gb)
    XCTAssertEqual(summary.requiredBytes, AppMigrator.requiredTargetBytes(appSize: gb))
}
```

- [ ] **Step 2: Run the test and verify it passes after Task 1 data preservation**

Run: `swift test --filter MigrationPlanPresentationTests/testReadyPlanSummaryRetainsExactByteValuesForMonospacedRendering`

Expected: PASS, confirming UI formatting receives raw values rather than preformatted strings.

- [ ] **Step 3: Make only the approved visual changes**

Use `MockTheme.accent` for the single primary “生成安全计划” action. Demote `迁移历史`, bulk restore, space planning and disk-retirement commands to text or bordered secondary controls. Give migration status cards the existing 10-point rounded card treatment with one subtle border/shadow; remove competing gradients except the approved primary action. Ensure status uses `StatusPill` plus explicit label text, numerical summaries use `.monospacedDigit()`, and any phase transition animation is disabled when `accessibilityReduceMotion` is true. Do not change the sidebar’s selected-navigation behavior or unrelated page layout.

- [ ] **Step 4: Run full verification and inspect the diff**

Run: `swift test && swift build -c release && git diff --check HEAD~1..HEAD`

Expected: PASS; no whitespace errors; visual changes remain limited to the approved migration experience and shared primitives.

- [ ] **Step 5: Commit visual polish**

```bash
git add Sources/Suishouqian/ContentView.swift Sources/Suishouqian/Views/MigrationPanel.swift Sources/Suishouqian/Views/AppListView.swift Sources/Suishouqian/Views/Design.swift Tests/SuishouqianTests/MigrationPlanPresentationTests.swift
git commit -m "style: refine migration safety hierarchy"
```

## Plan Self-Review

- **Spec coverage:** Tasks 1–4 cover the reviewed-plan route, blocked/ready/running/succeeded/cancelled/failed states, service-boundary preservation and every specified migration entry. Task 5 covers the approved calm-control visual language and accessibility requirements.
- **Deferred-marker scan:** No deferred implementation markers or generic error-handling directions are present; each task names affected files, exact interfaces, test assertions and commands.
- **Type consistency:** `MigrationPlanRequest`, `MigrationPlanState`, `MigrationPlanSummary`, `MigrationPlanItem`, `MigrationExecutionPhase`, and `MigrationOutcome` are defined in Task 1 before Tasks 2–5 consume them. The confirmation callback consistently uses `MigrationPlanSummary`.
- **Review focus coverage:** Missing drive and insufficient capacity are tested in Task 1; stale selection is tested and rechecked in Task 4; cancellation and mixed outcomes are tested in Tasks 1 and 3, then manually exercised in Task 4.
