import Foundation
import Metal
import CoreMedia

#if canImport(Syphon)
import Syphon
#endif

/// Thin adapter over Syphon's Metal API.
/// All third-party Syphon code remains in the normal host process.
final class SyphonFrameSource {
    var onTexture: ((MTLTexture, CMTime) -> Void)?

    private let device: MTLDevice
    private var frameCounter: UInt64 = 0

    #if canImport(Syphon)
    private var client: SyphonMetalClient?
    #endif

    init(device: MTLDevice) {
        self.device = device
    }

    static func availableServerDisplayNames() -> [String] {
        #if canImport(Syphon)
        return SyphonServerDirectory.shared().servers.map { description in
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? "Unknown App"
            let name = description[SyphonServerDescriptionNameKey] as? String ?? "Unnamed"
            return "\(app) — \(name)"
        }
        #else
        return ["Syphon framework not linked"]
        #endif
    }

    func start(displayName: String?) throws {
        #if canImport(Syphon)
        let servers = SyphonServerDirectory.shared().servers
        guard !servers.isEmpty else {
            throw NSError(domain: "SyphonCamera", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No Syphon servers found"])
        }

        let selected = servers.first { description in
            let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
            return displayName == "\(app) — \(name)"
        } ?? servers[0]

        client = SyphonMetalClient(
            serverDescription: selected,
            device: device,
            options: nil
        ) { [weak self] client in
            guard let self,
                  client.isValid,
                  let texture = client.newFrameImage() else { return }

            let pts = CMTime(
                value: CMTimeValue(self.frameCounter),
                timescale: CameraConstants.fps
            )
            self.frameCounter += 1
            self.onTexture?(texture, pts)
        }

        guard client?.isValid == true else {
            throw NSError(domain: "SyphonCamera", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Syphon server"])
        }
        #else
        throw NSError(
            domain: "SyphonCamera",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey:
                "Syphon.framework is not linked. Use Test Pattern or add Syphon to the app target."]
        )
        #endif
    }

    func stop() {
        #if canImport(Syphon)
        client?.stop()
        client = nil
        #endif
    }
}
