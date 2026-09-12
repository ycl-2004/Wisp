// Export the actual production scripts for synthetic browser acceptance.
// swiftc -parse-as-library Wisp/Capture/PageTextScript.swift tools/non-audio/ExportPageScripts.swift -o /tmp/wisp-page-scripts
import Foundation

@main struct ExportPageScripts {
    static func main() throws {
        let scripts = ["begin": PageTextScript.beginJS, "step": PageTextScript.stepJS,
                       "finish": PageTextScript.finishJS, "cleanup": PageTextScript.cleanupJS]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: scripts, options: .sortedKeys))
    }
}
