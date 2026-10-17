// OpenClipJSHostSupport.swift
// OpenClip
//
// Threading/support boxes for OpenClipJSHost: the watchdog timeout flag, the sync-evaluation
// gate, JS-context/value/runloop boxes, and the mutable collections used to ferry results out of
// the JS effect blocks. Split out of OpenClipJSHost.swift.
import Foundation
import JavaScriptCore
import Core

private typealias OpenClipJSTerminationCallback = @convention(c) (
    JSContextRef?,
    UnsafeMutableRawPointer?
) -> Bool

// Declared here: the JSContextGroup execution-limit C API lives in JSContextRefPrivate.h, not the public module.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func setJSContextGroupExecutionTimeLimit(
    _ group: JSContextGroupRef,
    _ limit: Double,
    _ callback: OpenClipJSTerminationCallback?,
    _ callbackData: UnsafeMutableRawPointer?
)

@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func clearJSContextGroupExecutionTimeLimit(_ group: JSContextGroupRef)

private func terminateTimedOutScript(
    _: JSContextRef?,
    _ callbackData: UnsafeMutableRawPointer?
) -> Bool {
    if let callbackData {
        Unmanaged<TimeoutFlag>.fromOpaque(callbackData).takeUnretainedValue().markTimedOut()
    }
    return true
}

/// Owns the JSC execution-time limit for one context; it terminates sync JS even while `evaluateScript` runs.
final class JSExecutionTimeLimit {
    private let context: JSContext
    private let group: JSContextGroupRef
    private let timeoutFlag: TimeoutFlag
    private var isCleared = false

    init(context: JSContext, timeout: TimeInterval, timeoutFlag: TimeoutFlag) {
        self.context = context
        group = JSContextGetGroup(context.jsGlobalContextRef)
        self.timeoutFlag = timeoutFlag
        setJSContextGroupExecutionTimeLimit(
            group,
            timeout,
            terminateTimedOutScript,
            Unmanaged.passUnretained(self.timeoutFlag).toOpaque()
        )
    }

    deinit {
        clear()
    }

    func clear() {
        guard !isCleared else { return }
        isCleared = true
        clearJSContextGroupExecutionTimeLimit(group)
    }
}

/// Caps concurrent sync evaluations. A budgeted run's slot is recovered by the execution limit; unbudgeted runs hold it until settled.
final class SyncEvaluationGate: @unchecked Sendable {
    private let lock = NSLock()
    let capacity: Int
    private var inFlight = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < capacity else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }
}

/// Weak context box so off-thread URLSession completions never hold the last JS reference (see `known-debt.md`).
/// The evaluation retains its context for the run, so this is live exactly while the run is.
final class WeakJSContextBox: @unchecked Sendable {
    weak var context: JSContext?
    init(_ context: JSContext) { self.context = context }
}

/// Weak, Sendable handle so an off-thread closure can reach a JS-thread object without retaining it (issue #47).
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// JS-thread-owned resolve/reject pairs for in-flight fetches, keyed by task identifier.
/// Completions look them up on the JS runloop so no JS reference is held off-thread (see `known-debt.md`).
final class FetchResolvers: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: (resolve: JSValue, reject: JSValue)] = [:]

    func register(_ identifier: Int, resolve: JSValue, reject: JSValue) {
        lock.lock()
        entries[identifier] = (resolve, reject)
        lock.unlock()
    }

    /// Removes and returns the pair for `identifier`, or nil if already settled or removed.
    func take(_ identifier: Int) -> (resolve: JSValue, reject: JSValue)? {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: identifier)
    }

    /// Drops every pending pair on the calling (JS) thread so unsettled fetches cannot keep the context alive (issue #47).
    func clearPending() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

final class RunLoopBox: @unchecked Sendable {
    let runLoop: CFRunLoop
    init(_ runLoop: CFRunLoop) { self.runLoop = runLoop }
}

/// Boxes effect state so `@convention(block)` closures capture a Sendable reference (region isolation checker in `Task.detached`).
final class CollectedBox: @unchecked Sendable {
    var value: OpenClipJSHost.Collected
    init() { self.value = OpenClipJSHost.Collected() }
}

/// Call-ordered side effects collected from the JS effect blocks (mirrors CollectedBox rationale).
final class EffectsBox: @unchecked Sendable {
    var value: [OpenClipJSHost.Effect]
    init() { self.value = [] }
}

/// Settled by the promise bridge on the JS thread and read by the host's pump loop on that thread.
final class PromiseState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSettled = false
    private var _resolvedValue: JSValue?
    private var _rejectedValue: JSValue?

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSettled
    }

    var resolvedValue: JSValue? {
        lock.lock()
        defer { lock.unlock() }
        return _resolvedValue
    }

    var rejectedValue: JSValue? {
        lock.lock()
        defer { lock.unlock() }
        return _rejectedValue
    }

    func resolve(_ value: JSValue) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isSettled else { return }
        _resolvedValue = value
        _isSettled = true
    }

    func reject(_ error: JSValue) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isSettled else { return }
        _rejectedValue = error
        _isSettled = true
    }

    /// Drops settled JSValues after the outcome is consumed; retaining them would keep the JSVirtualMachine alive via `openclip` (issue #47).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _resolvedValue = nil
        _rejectedValue = nil
    }
}

/// Carries the stable `taskIdentifier` to the completion thread, which removes its own task.
/// Written on the JS thread before `resume()`, read on the completion thread.
final class TaskIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func set(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value = value
    }
}

/// Thread-safe in-flight task tracker; `cancelAll()` is terminal.
/// Tasks added after cancellation starts are cancelled immediately, so none can escape.
final class FetchTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [URLSessionDataTask] = []
    private var ended = false
    private var closeHandler: (@Sendable () -> Void)?
    private var didClose = false

    /// True after the evaluation ends. The fetch bridge reads this before it calls the JavaScript VM.
    var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func add(_ task: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = ended
        if !shouldCancel {
            tasks.append(task)
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func remove(_ identifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeAll(where: { $0.taskIdentifier == identifier })
    }

    /// Runs once when the evaluation ends. Apple retains a `URLSession` until invalidated, so this invalidates the per-run session (issue #46).
    /// If already closed, runs immediately so a racing registration is not dropped.
    func setCloseHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if didClose {
            lock.unlock()
            handler()
            return
        }
        closeHandler = handler
        lock.unlock()
    }

    func finish() {
        lock.lock()
        ended = true
        let handler = takeCloseHandlerLocked()
        lock.unlock()
        handler?()
    }

    func cancelAll() {
        lock.lock()
        ended = true
        let currentTasks = tasks
        tasks.removeAll()
        let handler = takeCloseHandlerLocked()
        lock.unlock()
        for task in currentTasks {
            task.cancel()
        }
        handler?()
    }

    /// Consumes the close handler exactly once, so `finish()` and `cancelAll()` cannot both run it.
    private func takeCloseHandlerLocked() -> (@Sendable () -> Void)? {
        guard !didClose else { return nil }
        didClose = true
        defer { closeHandler = nil }
        return closeHandler
    }
}
