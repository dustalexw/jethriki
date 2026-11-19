import Foundation
import JavaScriptCore

/// Runs JavaScript for yt-dlp in Apple's JavaScriptCore. YouTube needs a JavaScript runtime to unlock most
/// formats; on a computer that's Deno or Node, which can't run on iOS. jethriki_host.py registers this as
/// yt-dlp's "jsc" runtime and calls the two C functions below through jp_set_javascript.
enum JavaScriptBridge {
    /// run(script, &failed) -> malloc'd UTF-8 text: everything the script printed with console.log, or the error.
    static let run: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer? = { script, failed in
        let result = evaluate(script.map { String(cString: $0) } ?? "")
        failed?.pointee = result.error == nil ? 0 : 1
        return UnsafeMutableRawPointer(strdup(result.error ?? result.output))
    }

    static let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in free(pointer) }

    /// Evaluates a script in a fresh context with a console that records what is logged.
    static func evaluate(_ script: String) -> (output: String, error: String?) {
        guard let context = JSContext() else { return ("", "JavaScriptCore couldn't start") }
        var printed: [String] = []
        var problems: [String] = []
        var thrown: String?
        context.exceptionHandler = { _, exception in
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            thrown = [exception?.toString() ?? "exception", stack].filter { !$0.isEmpty && $0 != "undefined" }.joined(separator: "\n")
        }
        func line() -> String {
            (JSContext.currentArguments() ?? []).compactMap { ($0 as? JSValue)?.toString() }.joined(separator: " ")
        }
        let log: @convention(block) () -> Void = { printed.append(line()) }
        let error: @convention(block) () -> Void = { problems.append(line()) }
        let console = JSValue(newObjectIn: context)!
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        console.setObject(log, forKeyedSubscript: "info" as NSString)
        console.setObject(log, forKeyedSubscript: "debug" as NSString)
        console.setObject(error, forKeyedSubscript: "warn" as NSString)
        console.setObject(error, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.evaluateScript(script)
        if let thrown { return (printed.joined(separator: "\n"), thrown) }
        if printed.isEmpty, !problems.isEmpty { return ("", problems.joined(separator: "\n")) }
        return (printed.joined(separator: "\n"), nil)
    }
}
