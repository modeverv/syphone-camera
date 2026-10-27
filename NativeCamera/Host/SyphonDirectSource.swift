import Foundation
#if canImport(Syphon)
import Syphon
#endif

/// Reports why an ordinary Syphon stream cannot enter the strict direct path.
/// Retaining its texture keeps the allocation alive, but does not stop its
/// producer from rewriting that allocation while another process consumes it.
final class SyphonDirectSource {
    static func diagnosticReport() -> String {
        var lines = [
            "Strict Syphon input: unavailable for ordinary mutable producers.",
            "A producer must supply immutable IOSurface-backed frames with a reuse/ownership contract.",
            "SyphonMetalClient.newFrameImage() alone does not provide that contract; no frames were submitted."
        ]
#if canImport(Syphon)
        let servers = SyphonServerDirectory.shared().servers
        let names = servers.map { description -> String in
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? "(unknown app)"
            let name = description[SyphonServerDescriptionNameKey] as? String ?? "(unnamed server)"
            return app + "/" + name
        }.sorted()
        lines.append("Currently discovered Syphon servers: \(names.count)")
        lines.append(contentsOf: names.map { "- " + $0 })
#else
        lines.append("Syphon discovery framework is not linked into this build.")
#endif
        return lines.joined(separator: "\n")
    }
}
