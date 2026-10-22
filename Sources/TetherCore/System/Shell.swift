import Foundation

public enum Shell {
    /// Termination is evidence about the directly launched process, not its physical effect
    /// or arbitrary descendants. Global power writers must be launched without a shell.
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
        public let processID: Int32?
        public let terminationConfirmed: Bool
        /// Preserve the actual exit/signal status separately from the timeout status 124.
        public let exitStatus: Int32?
    }
    public static let terminationGrace: TimeInterval = 0.2
    public static let terminationConfirmationWindow: TimeInterval = 0.5

    @discardableResult
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10,
                           maxOutputBytes: Int = 1_048_576, keepTail: Bool = false,
                           inheritedInput: FileHandle? = nil,
                           requiresStartPermission: Bool = false,
                           didStart: ((Int32) -> Bool)? = nil) -> Result {
        // NaN/infinity would otherwise remove the deadline and leave a child unbounded.
        guard timeout.isFinite else {
            return Result(status: -1, output: "Invalid command timeout", timedOut: false,
                processID: nil, terminationConfirmed: true, exitStatus: nil)
        }
        let deadline = ContinuousTime.now + max(0.01, timeout)
        let process = Process()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        // A native writer gate reads this private pipe on stderr before exec.
        // Its write end belongs only to this parent: death before registration
        // sends EOF instead of letting an unregistered power command start.
        let permission = requiresStartPermission ? Pipe() : nil
        if let permission {
            guard fcntl(permission.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(permission.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(permission.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                return Result(status: -1, output: "Cannot prepare writer start permission", timedOut: false,
                    processID: nil, terminationConfirmed: true, exitStatus: nil)
            }
        }
        defer {
            try? permission?.fileHandleForReading.close()
            try? permission?.fileHandleForWriting.close()
        }
        process.standardOutput = pipe
        if let permission { process.standardError = permission.fileHandleForReading }
        else { process.standardError = pipe }
        process.standardInput = inheritedInput ?? FileHandle.nullDevice
        do { try process.run() } catch {
            return Result(status: -1, output: "\(error)", timedOut: false,
                processID: nil, terminationConfirmed: true, exitStatus: nil)
        }
        let pid = process.processIdentifier
        var registered = didStart?(pid) ?? true
        if let permission {
            try? permission.fileHandleForReading.close()
            var token = UInt8(0xA5)
            if registered {
                registered = Darwin.write(permission.fileHandleForWriting.fileDescriptor, &token, 1) == 1
            }
            try? permission.fileHandleForWriting.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let limit = max(0, maxOutputBytes)
        var eof = false, timedOut = false
        while !eof || process.isRunning {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if keepTail {
                    data.append(contentsOf: buffer.prefix(count))
                    // Compact in chunks rather than shifting a large buffer for each read.
                    if data.count > limit, data.count - limit > limit { data = Data(data.suffix(limit)) }
                } else {
                    data.append(contentsOf: buffer.prefix(min(count, max(0, limit - data.count))))
                }
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { eof = true }
            if !registered || ContinuousTime.now >= deadline {
                timedOut = true
                if process.isRunning {
                    process.terminate()
                    let grace = ContinuousTime.now + terminationGrace
                    while process.isRunning, ContinuousTime.now < grace { usleep(10_000) }
                    if process.isRunning {
                        _ = kill(pid, SIGKILL)
                        // Sending SIGKILL is not proof that the writer stopped. Await the
                        // actual Process termination observation, with a separate bound.
                        _ = terminated.wait(timeout: .now() + terminationConfirmationWindow)
                    }
                }
                break
            }
            if count <= 0 {
                if !eof {
                    // Wait for the pipe, not a fixed sleep per empty read. Large pmset
                    // logs otherwise spend their timeout waiting while data is ready.
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                } else if process.isRunning { usleep(10_000) }
            }
        }
        if keepTail { data = Data(data.suffix(limit)) }
        let confirmed = !process.isRunning
        // Never call the unbounded waitUntilExit after an unconfirmed termination.
        let exitStatus = confirmed ? process.terminationStatus : nil
        let output = String(decoding: data, as: UTF8.self)
        if timedOut {
            let notice = registered ? (confirmed ? "\nCommand timed out" : "\nCommand timed out; process termination unconfirmed")
                : "\nCommand writer registration failed or start permission was not delivered"
            return Result(status: registered ? 124 : -2, output: output + notice, timedOut: registered,
                processID: pid, terminationConfirmed: confirmed, exitStatus: exitStatus)
        }
        return Result(status: exitStatus ?? -1, output: output, timedOut: false,
            processID: pid, terminationConfirmed: confirmed, exitStatus: exitStatus)
    }
}
