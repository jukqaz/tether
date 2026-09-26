import Foundation
import TetherCore

setvbuf(stdout, nil, _IOLBF, 0)
// launchd appends to the log forever; start over once it passes 1 MB.
var logInfo = stat()
if fstat(STDOUT_FILENO, &logInfo) == 0, (logInfo.st_mode & S_IFMT) == S_IFREG, logInfo.st_size > 1_000_000 {
    ftruncate(STDOUT_FILENO, 0)
}
let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let helper = Helper(dryRun: arguments.contains("--dry-run"),
                    controlPath: option("--control") ?? TetherPaths.controlPath,
                    statusPath: option("--status") ?? TetherPaths.statusPath,
                    fakePath: option("--fake"))
helper.start()
RunLoop.main.run()
