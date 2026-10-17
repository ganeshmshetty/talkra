// JSNativeFetch.swift
// OpenClip
//
// Shared URLSession-backed fetch bridge for the JavaScript runtime. Installs
// `openclip.__nativeFetch` and the `openclip.fetch` polyfill into a JSContext
// that already has a global `openclip` object.
import Foundation
import JavaScriptCore
import Darwin
import Core

enum JSNativeFetch {
    /// Installs `openclip.__nativeFetch` and the `openclip.fetch` polyfill. All JS VM access
    /// stays on the context's creating thread; URLSession completions only schedule work onto its CFRunLoop.
    @discardableResult
    static func installNativeFetch(in context: JSContext, session: URLSession, fetchTasks: FetchTaskBox) -> FetchResolvers? {
        guard let openclip = context.objectForKeyedSubscript("openclip" as NSString),
              !openclip.isUndefined, !openclip.isNull, openclip.isObject else { return nil }

        // Weak so the block on `openclip` does not retain the context (issue #47).
        let weakContextBox = WeakJSContextBox(context)
        // Resolvers stay on this JS thread; the off-thread completion reaches them only via a weak box.
        let resolvers = FetchResolvers()
        // Boxed so CFRunLoopGetCurrent() stays out of the @Sendable capture region.
        let runLoopBox = RunLoopBox(CFRunLoopGetCurrent())
        // Rebuilt with a redirect-validating delegate, keeping the caller's configuration (e.g. MockURLProtocol in tests).
        let policySession = PolicySession(from: session)
        // Invalidate at run end so the session, delegate, and Mach ports are released (issue #46).
        fetchTasks.setCloseHandler { policySession.session.invalidateAndCancel() }

        let nativeFetchBlock: @convention(block) (String, JSValue, JSValue, JSValue) -> Void = { urlString, options, resolve, reject in
            guard let url = URL(string: urlString) else {
                guard let currentContext = JSContext.current(),
                      let err = JSNativeFetch.jsError("Invalid URL: \(urlString)", in: currentContext) else { return }
                reject.call(withArguments: [err])
                return
            }
            // Destination policy for the initial URL; redirects are checked by JSNativeFetchRedirectDelegate.
            guard JSNativeFetch.isDestinationAllowed(url) else {
                guard let currentContext = JSContext.current(),
                      let err = JSNativeFetch.jsError("Destination not allowed: \(urlString)", in: currentContext) else { return }
                reject.call(withArguments: [err])
                return
            }
            let request = JSNativeFetch.makeURLRequest(url: url, options: options)
            let taskID = TaskIdentifierBox()
            // The completion runs on a worker thread: capture only Sendable scalars and weak boxes (issue #47).
            let weakResolvers = WeakRef(resolvers)
            let task = policySession.session.dataTask(with: request) { data, response, error in
                // Remove by identifier; reading the mutable `task` here would cross threads.
                fetchTasks.remove(taskID.value)
                // Also fires for cancelled tasks, and after the evaluation has ended.
                guard !fetchTasks.isEnded else { return }
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorMessage = error.map { "Fetch failed: \($0.localizedDescription)" }
                CFRunLoopPerformBlock(runLoopBox.runLoop, CFRunLoopMode.defaultMode.rawValue) {
                    // May run in a later evaluation on this thread, after this one ended: never touch the VM then.
                    guard !fetchTasks.isEnded,
                          let currentContext = weakContextBox.context,
                          let pending = weakResolvers.value?.take(taskID.value) else { return }
                    if let errorMessage {
                        if let err = JSNativeFetch.jsError(errorMessage, in: currentContext) {
                            pending.reject.call(withArguments: [err])
                        }
                    } else if let resp = JSNativeFetch.fetchResponse(status: status, body: body, context: currentContext) {
                        pending.resolve.call(withArguments: [resp])
                    }
                }
                CFRunLoopWakeUp(runLoopBox.runLoop)
            }
            // Track and register before resume so an immediate completion finds its resolver and the watchdog can cancel it.
            taskID.set(task.taskIdentifier)
            fetchTasks.add(task)
            resolvers.register(task.taskIdentifier, resolve: resolve, reject: reject)
            task.resume()
        }
        openclip.setObject(nativeFetchBlock, forKeyedSubscript: "__nativeFetch" as NSString)
        context.evaluateScript(fetchPolyfillScript)
        // Lets the host drop pending resolve/reject pairs on the JS thread at run end.
        return resolvers
    }

    /// Effectively no timeout; fetches are bounded only by cancelling them from the loading toast.
    private static let fetchTimeout: TimeInterval = 60 * 60 * 24 * 365

    /// Maps `fetch(url, options)` onto a URLRequest.
    static func makeURLRequest(url: URL, options: JSValue) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout

        let methodValue = options.objectForKeyedSubscript("method")
        if let methodValue, !methodValue.isUndefined, !methodValue.isNull {
            if let method = methodValue.toString(), !method.isEmpty {
                request.httpMethod = method.uppercased()
            }
        } else {
            request.httpMethod = "GET"
        }

        if let headersValue = options.objectForKeyedSubscript("headers"),
           headersValue.isObject,
           let headers = headersValue.toDictionary() {
            for (key, value) in headers {
                if let name = key as? String, let headerValue = value as? String {
                    request.setValue(headerValue, forHTTPHeaderField: name)
                }
            }
        }

        if let bodyValue = options.objectForKeyedSubscript("body"),
           !bodyValue.isUndefined, !bodyValue.isNull,
           let body = bodyValue.toString(), !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }
        return request
    }

    /// Builds the JS response object: `{ status, ok, text(), json() }`.
    static func fetchResponse(status: Int, body: String, context: JSContext) -> JSValue? {
        guard let response = JSValue(newObjectIn: context) else { return nil }
        response.setObject(status, forKeyedSubscript: "status")
        response.setObject(status >= 200 && status < 300, forKeyedSubscript: "ok")

        let textBlock: @convention(block) () -> String = { body }
        response.setObject(textBlock, forKeyedSubscript: "text")

        // Must not capture the context: context -> JSValue -> block -> context keeps the VM alive (issue #47).
        let jsonBlock: @convention(block) () -> Any = {
            guard let currentContext = JSContext.current() else { return NSNull() }
            if let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
            Log.js.debug("response.json() received non-JSON body")
            if let err = JSNativeFetch.jsError("Invalid JSON response", in: currentContext) {
                currentContext.exception = err
            }
            return NSNull()
        }
        response.setObject(jsonBlock, forKeyedSubscript: "json")
        return response
    }

    /// Creates a JS `Error`, or a plain object if the constructor is gone.
    static func jsError(_ message: String, in context: JSContext) -> JSValue? {
        if let errorConstructor = context.objectForKeyedSubscript("Error"),
           !errorConstructor.isUndefined, !errorConstructor.isNull {
            return errorConstructor.call(withArguments: [message])
        }
        return JSValue(object: ["message": message], in: context)
    }

    /// Destination policy (SSRF guard): http/https only, no private or link-local hosts, and
    /// loopback only on unprivileged, non-service ports. Also applied to every redirect hop.
    static func isDestinationAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }

        if isLoopbackHost(host) {
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return isAllowedLocalPort(port)
        }

        return !isLocalOrPrivateHost(host)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bareNoZone = String(bare.split(separator: "%").first ?? Substring(bare))
        if bareNoZone == "localhost" || bareNoZone == "local" || bareNoZone == "ip6-localhost" || bareNoZone.hasSuffix(".localhost") {
            return true
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, bareNoZone, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = UInt8((value >> 24) & 0xFF)
            return a == 127
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, bareNoZone, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return bytes[12] == 127
            }
        }

        return false
    }

    static func isAllowedLocalPort(_ port: Int) -> Bool {
        guard port >= 1024 && port <= 65535 else { return false }
        let blockedPorts: Set<Int> = [
            2375, 2376, // Docker daemon
            3306,       // MySQL
            5432,       // PostgreSQL
            6379,       // Redis
            11211,      // Memcached
            27017,      // MongoDB
            9200        // Elasticsearch
        ]
        return !blockedPorts.contains(port)
    }

    /// Literal and localhost hosts only; hostnames resolving to private addresses are not checked (no DNS here).
    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bareNoZone = String(bare.split(separator: "%").first ?? Substring(bare))
        if bareNoZone == "localhost" || bareNoZone == "local" || bareNoZone == "ip6-localhost" || bareNoZone.hasSuffix(".localhost") {
            return true
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, bareNoZone, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = UInt8((value >> 24) & 0xFF)
            let b = UInt8((value >> 16) & 0xFF)
            return isPrivateIPv4(a: a, b: b)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, bareNoZone, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return true }                       // ::
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // ::1
            if bytes[0] == 0xfe && (bytes[1] & 0xC0) == 0x80 { return true }       // fe80::/10 link-local
            if bytes[0] == 0xfc || bytes[0] == 0xfd { return true }                // fc00::/7 ULA
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return isPrivateIPv4(a: bytes[12], b: bytes[13]) // ::ffff:a.b.c.d
            }
            return false
        }
        return false
    }

    private static func isPrivateIPv4(a: UInt8, b: UInt8) -> Bool {
        if a == 127 { return true }                                  // 127/8 loopback
        if a == 10 { return true }                                   // 10/8
        if a == 172 && b >= 16 && b <= 31 { return true }            // 172.16/12
        if a == 192 && b == 168 { return true }                      // 192.168/16
        if a == 169 && b == 254 { return true }                      // 169.254/16 link-local
        if a == 0 { return true }                                    // 0.0.0.0/8 unspecified
        return false
    }

    /// URLSession rebuilt with the redirect-validating delegate; invalidated when the evaluation ends (issue #46).
    private final class PolicySession: @unchecked Sendable {
        let session: URLSession
        let delegate: JSNativeFetchRedirectDelegate
        init(from base: URLSession) {
            let delegate = JSNativeFetchRedirectDelegate()
            self.delegate = delegate
            self.session = URLSession(configuration: base.configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    /// Returning nil from `willPerformHTTPRedirection` aborts a redirect that fails the destination policy.
    private final class JSNativeFetchRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, JSNativeFetch.isDestinationAllowed(url) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    static let fetchPolyfillScript = """
    openclip.fetch = function(url, options) {
        return new Promise(function(resolve, reject) {
            openclip.__nativeFetch(String(url), options || {}, resolve, reject);
        });
    };
    """
}
