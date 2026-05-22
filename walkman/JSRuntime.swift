import Foundation
import JavaScriptCore

/// Wraps a single lx-music v4 user script in a JSContext.
/// Implements the contract defined in Resources/user-api-preload.js.
final class JSScriptRuntime {
    let scriptID: String
    let metadata: ScriptMetadata
    private let context: JSContext
    private let key: String
    private let queue = DispatchQueue(label: "JSScriptRuntime.\(UUID().uuidString)")
    private var timeoutCallbacks: [Int: DispatchWorkItem] = [:]

    private var pendingRequests: [String: (Result<Any, Error>) -> Void] = [:]
    private var initContinuation: CheckedContinuation<ScriptCapabilities, Error>?
    private var inited: Bool = false
    private(set) var capabilities: ScriptCapabilities = ScriptCapabilities(sources: [:])

    struct ScriptMetadata {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let homepage: String
    }

    enum RuntimeError: LocalizedError {
        case contextCreateFailed
        case preloadMissing
        case scriptThrew(String)
        case actionFailed(String)
        case notInited
        case unsupported(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .contextCreateFailed: return "无法创建 JS 上下文"
            case .preloadMissing: return "缺少用户脚本预加载文件"
            case .scriptThrew(let msg): return "脚本抛出异常: \(msg)"
            case .actionFailed(let msg): return "脚本调用失败: \(msg)"
            case .notInited: return "脚本尚未初始化"
            case .unsupported(let s): return "不支持: \(s)"
            case .timeout: return "脚本响应超时"
            }
        }
    }

    init(metadata: ScriptMetadata, rawScript: String) throws {
        guard let ctx = JSContext() else { throw RuntimeError.contextCreateFailed }
        self.context = ctx
        self.metadata = metadata
        self.scriptID = metadata.id
        self.key = UUID().uuidString

        ctx.exceptionHandler = { _, exc in
            print("[JSRuntime] exception: \(exc?.toString() ?? "?")")
        }
        // Console — receive all arguments (scripts often pass `console.log('label', value)`).
        // Joining all args mirrors web/Node's space-separated formatting.
        let makeConsole: (String) -> @convention(block) () -> Void = { level in
            return {
                let args = JSContext.currentArguments() ?? []
                let parts: [String] = args.compactMap { ($0 as? JSValue)?.toString() }
                print("[JS \(level)] \(parts.joined(separator: " "))")
            }
        }
        let console = JSValue(newObjectIn: ctx)!
        console.setObject(makeConsole("log"),   forKeyedSubscript: "log" as NSString)
        console.setObject(makeConsole("info"),  forKeyedSubscript: "info" as NSString)
        console.setObject(makeConsole("warn"),  forKeyedSubscript: "warn" as NSString)
        console.setObject(makeConsole("error"), forKeyedSubscript: "error" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        try installNativeCallbacks()

        guard let preloadURL = Bundle.main.url(forResource: "user-api-preload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            throw RuntimeError.preloadMissing
        }
        ctx.evaluateScript(preload)
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("preload: \(exc.toString() ?? "?")")
        }

        // Call lx_setup(key, id, name, description, version, author, homepage, rawScript)
        let setup = ctx.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [
            key, metadata.id, metadata.name, metadata.description,
            metadata.version, metadata.author, metadata.homepage, rawScript
        ])
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("lx_setup: \(exc.toString() ?? "?")")
        }

        // Evaluate the user script directly — mirrors QuickJS.java loadScript() which calls
        // jsContext.evaluate(script) without any wrapping. The v4 source is itself an IIFE.
        ctx.evaluateScript(rawScript)
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("user script: \(exc.toString() ?? "?")")
        }
    }

    /// Wait for the script to call `lx.send('inited', info)`. Times out after `timeout` seconds.
    func waitForInit(timeout: TimeInterval = 10) async throws -> ScriptCapabilities {
        if inited { return capabilities }
        return try await withThrowingTaskGroup(of: ScriptCapabilities.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScriptCapabilities, Error>) in
                    self.queue.sync { self.initContinuation = cont }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RuntimeError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Ask the script to perform an action: musicUrl / lyric / pic.
    func requestAction(source: SourceID, action: String, info: [String: Any]) async throws -> Any {
        if !inited { throw RuntimeError.notInited }
        let requestKey = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            queue.sync { self.pendingRequests[requestKey] = { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }}
            let payload: [String: Any] = [
                "requestKey": requestKey,
                "data": ["source": source.rawValue, "action": action, "info": info]
            ]
            sendToScript(action: "request", payload: payload)
        }
    }

    private func sendToScript(action: String, payload: Any?) {
        let dataString: String
        if let payload {
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let s = String(data: data, encoding: .utf8) {
                dataString = s
            } else {
                dataString = "null"
            }
        } else {
            dataString = ""
        }
        let native = context.objectForKeyedSubscript("__lx_native__")
        if payload == nil {
            native?.call(withArguments: [key, action])
        } else {
            native?.call(withArguments: [key, action, dataString])
        }
    }

    // MARK: - Native callbacks installed before preload runs

    private func installNativeCallbacks() throws {
        // _nativeCall(key, action, dataString) — script => host
        let nativeCall: @convention(block) (String, String, String) -> Void = { [weak self] key, action, dataString in
            guard let self else { return }
            guard key == self.key else { return }
            self.handleScriptCall(action: action, rawData: dataString)
        }
        context.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        // set_timeout
        let setTimeout: @convention(block) (NSNumber, NSNumber) -> Void = { [weak self] id, timeoutMS in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.queue.sync { self?.timeoutCallbacks.removeValue(forKey: id.intValue) }
                self?.sendToScript(action: "__set_timeout__", payload: id.intValue)
            }
            self.queue.sync { self.timeoutCallbacks[id.intValue] = work }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMS.intValue), execute: work)
        }
        context.setObject(setTimeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)

        // utils_str2b64
        let str2b64: @convention(block) (String) -> String = { s in CryptoBridge.base64Encode(s) }
        context.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)

        // utils_b642buf — returns JSON string of byte array (preload does JSON.parse)
        let b642buf: @convention(block) (String) -> String = { b64 in
            guard let bytes = CryptoBridge.base64DecodeToBytes(b64) else { return "[]" }
            if let data = try? JSONSerialization.data(withJSONObject: bytes),
               let s = String(data: data, encoding: .utf8) { return s }
            return "[]"
        }
        context.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)

        // utils_str2md5
        let str2md5: @convention(block) (String) -> String = { s in CryptoBridge.md5(s) }
        context.setObject(str2md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)

        // utils_aes_encrypt(b64data, b64key, b64iv, mode)
        let aesEnc: @convention(block) (String, String, String, String) -> String = { d, k, iv, mode in
            CryptoBridge.aesEncrypt(dataB64: d, keyB64: k, ivB64: iv, mode: mode) ?? ""
        }
        context.setObject(aesEnc, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)

        // utils_rsa_encrypt(b64data, key, padding)
        let rsaEnc: @convention(block) (String, String, String) -> String = { d, k, p in
            CryptoBridge.rsaEncrypt(dataB64: d, pemBody: k, padding: p) ?? ""
        }
        context.setObject(rsaEnc, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)
    }

    private func handleScriptCall(action: String, rawData: String) {
        let parsed: Any? = {
            guard let data = rawData.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }()
        switch action {
        case "init":
            handleInit(parsed)
        case "showUpdateAlert":
            print("[JSRuntime] updateAlert: \(parsed ?? "nil")")
        case "request":
            handleHTTPRequest(parsed)
        case "cancelRequest":
            if let key = parsed as? String { ScriptHTTPClient.shared.cancel(requestKey: key) }
        case "response":
            handleScriptResponse(parsed)
        default:
            print("[JSRuntime] unknown script call: \(action)")
        }
    }

    private func handleInit(_ data: Any?) {
        guard let dict = data as? [String: Any] else {
            failInit(error: RuntimeError.actionFailed("init payload not a dict"))
            return
        }
        if let status = dict["status"] as? Bool, !status {
            let msg = dict["errorMessage"] as? String ?? "unknown"
            failInit(error: RuntimeError.actionFailed(msg))
            return
        }
        var caps = ScriptCapabilities(sources: [:])
        if let info = dict["info"] as? [String: Any],
           let sources = info["sources"] as? [String: Any] {
            for (key, val) in sources {
                guard let src = SourceID(rawValue: key),
                      let v = val as? [String: Any] else { continue }
                let actions = (v["actions"] as? [String]) ?? []
                let qstrs = (v["qualitys"] as? [String]) ?? []
                let qs = qstrs.compactMap { Quality(rawValue: $0) }
                caps.sources[src] = SourceCapability(
                    type: (v["type"] as? String) ?? "music",
                    actions: actions,
                    qualities: qs
                )
            }
        }
        capabilities = caps
        inited = true
        let cont = queue.sync { () -> CheckedContinuation<ScriptCapabilities, Error>? in
            let c = self.initContinuation; self.initContinuation = nil; return c
        }
        cont?.resume(returning: caps)
    }

    private func failInit(error: Error) {
        let cont = queue.sync { () -> CheckedContinuation<ScriptCapabilities, Error>? in
            let c = self.initContinuation; self.initContinuation = nil; return c
        }
        cont?.resume(throwing: error)
    }

    private func handleHTTPRequest(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let requestKey = dict["requestKey"] as? String,
              let url = dict["url"] as? String else { return }
        let options = (dict["options"] as? [String: Any]) ?? [:]
        ScriptHTTPClient.shared.send(requestKey: requestKey, url: url, options: options) { [weak self] error, response in
            guard let self else { return }
            // Mirror lx-music-mobile's contract: always send both fields, one is NSNull. Scripts
            // that use `if (error == null)` rely on a present-but-null key.
            var payload: [String: Any] = ["requestKey": requestKey]
            if let error {
                payload["error"] = error.localizedDescription
                payload["response"] = NSNull()
            } else if let response {
                payload["error"] = NSNull()
                payload["response"] = [
                    "statusCode": response.statusCode,
                    "statusMessage": response.statusMessage,
                    "headers": response.headers,
                    "body": response.body,
                ]
            } else {
                payload["error"] = "no response"
                payload["response"] = NSNull()
            }
            self.sendToScript(action: "response", payload: payload)
        }
    }

    private func handleScriptResponse(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let requestKey = dict["requestKey"] as? String else { return }
        let cb = queue.sync { () -> ((Result<Any, Error>) -> Void)? in
            let c = self.pendingRequests[requestKey]
            self.pendingRequests.removeValue(forKey: requestKey)
            return c
        }
        guard let cb else { return }
        if let status = dict["status"] as? Bool, status, let result = dict["result"] {
            cb(.success(result))
        } else {
            let msg = dict["errorMessage"] as? String ?? "unknown error"
            cb(.failure(RuntimeError.actionFailed(msg)))
        }
    }
}
