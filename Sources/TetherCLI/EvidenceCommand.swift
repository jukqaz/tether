import Foundation
import TetherCore

/// Development observations only. This path does not configure logging, acquire an
/// assertion, attach a work lease, mark an incident or send a sleep command.
func printPhysicalEvidence() -> Never {
    let began = Date().timeIntervalSince1970
    let native = SystemProbe.snapshot()
    var simulated = TetherPaths.serviceSocket != TetherPaths.productionSocket
    var helper: [String: Any] = ["available": false, "source": "unavailable"]
    do {
        let reply = try ServiceClient().perform(ServiceRequest(.snapshot))
        helper = ["available": reply.ok, "source": "live", "epoch": reply.epoch,
                  "revision": reply.revision, "protocolVersion": reply.version]
        if let status = reply.status { helper["status"] = evidenceObject(status) }
        helper["control"] = evidenceObject(reply.control)
        if let bridge = reply.workSessionBridge { helper["bridge"] = evidenceObject(bridge) }
        if let protection = reply.protection { helper["protection"] = evidenceObject(protection) }
        simulated = simulated || reply.protection?.dryRun == true
        if reply.error != nil { helper["errorPresent"] = true }
    } catch {
        helper["errorPresent"] = true
        // A stored heartbeat remains useful for investigation, but is not live ACK.
        if let status = JSONFile.read(Status.self, from: TetherPaths.statusPath) {
            helper["status"] = evidenceObject(status)
            helper["source"] = "file"
        }
    }
    let os: [String: Any?] = [
        "power": native.power.rawValue,
        "lidClosed": native.observedLidClosed,
        "sleepDisabled": native.observedSleepDisabled,
        "fullWake": native.observedFullWake,
        "displaySleeping": SystemProbe.builtInDisplaySleeping(),
        "displayTopology": native.displayTopology.rawValue,
        "batteryPercent": SystemProbe.batteryPercent(),
        "batteryTemperature": SystemProbe.batteryTemperature(),
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ]
    let result: [String: Any] = [
        "schemaVersion": 1, "build": TetherPaths.build,
        "simulated": simulated,
        "startedAt": began, "observedAt": Date().timeIntervalSince1970,
        "continuous": ContinuousTime.now, "bootID": ContinuousTime.bootID,
        "native": os.mapValues { $0 ?? NSNull() }, "helper": helper,
        // macOS screen-lock policy and graphical ownership do not prove unlocked
        // remote access. No undocumented lock-state API is used by the recorder.
        "screenLocked": NSNull(), "screenLockSource": "notCollected",
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch { fail("Could not encode physical-test observations") }
}

/// Remove private paths, user-provided sources and free-form error messages before
/// emitting the machine-readable sample. Unknown keys remain bounded by IPC.
private func evidenceObject<T: Encodable>(_ value: T) -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    guard let data = try? encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
    return scrubEvidence(object)
}

private func scrubEvidence(_ object: Any) -> Any {
    if let array = object as? [Any] { return array.map(scrubEvidence) }
    guard let input = object as? [String: Any] else { return object }
    var output: [String: Any] = [:]
    for (key, value) in input {
        if ["appPath", "holdSource", "executable", "commandLine"].contains(key) { continue }
        if ["error", "lastError", "lastApplyError"].contains(key) {
            output[key + "Present"] = !(value is NSNull)
        } else { output[key] = scrubEvidence(value) }
    }
    return output
}
