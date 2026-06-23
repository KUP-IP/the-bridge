// NBJobRunner/main.swift — Signed launchd callback helper (PKT-v1.9.2)
//
// Replaces /usr/bin/curl in job LaunchAgent plists so that macOS Background
// Task Management (BTM) attributes scheduled-job background items to
// The Bridge (via Developer ID code signature) instead of to the system
// curl binary. One BTM entry total, regardless of job count.
//
// Invoked by launchd as:
//   ProgramArguments = [ <helper_path>, <jobId> ]
//   EnvironmentVariables = { NB_SSE_PORT: "9700" }
//
// Behaviour: POST http://127.0.0.1:$NB_SSE_PORT/jobs/$jobId/run with a 30s
// timeout. Exits 0 on 2xx response, nonzero otherwise. No retries (launchd
// will surface failures via StandardErrorPath log).

import Foundation

@discardableResult
func log(_ msg: String) -> String {
    FileHandle.standardError.write(Data("[nb-job-runner] \(msg)\n".utf8))
    return msg
}

guard CommandLine.arguments.count >= 2 else {
    _ = log("missing jobId argument")
    exit(64) // EX_USAGE
}

let jobId = CommandLine.arguments[1]
let port = ProcessInfo.processInfo.environment["NB_SSE_PORT"] ?? "9700"

guard let url = URL(string: "http://127.0.0.1:\(port)/jobs/\(jobId)/run") else {
    _ = log("invalid URL for jobId=\(jobId) port=\(port)")
    exit(65) // EX_DATAERR
}

var req = URLRequest(url: url, timeoutInterval: 30)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.httpBody = Data("{}".utf8)

let sema = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 1

let task = URLSession.shared.dataTask(with: req) { _, resp, err in
    defer { sema.signal() }
    if let err = err {
        _ = log("request error jobId=\(jobId): \(err.localizedDescription)")
        exitCode = 69 // EX_UNAVAILABLE
        return
    }
    guard let http = resp as? HTTPURLResponse else {
        _ = log("non-HTTP response jobId=\(jobId)")
        exitCode = 70
        return
    }
    if (200...299).contains(http.statusCode) {
        exitCode = 0
    } else {
        _ = log("HTTP \(http.statusCode) jobId=\(jobId)")
        exitCode = 70
    }
}
task.resume()

_ = sema.wait(timeout: .now() + 32)
exit(exitCode)
