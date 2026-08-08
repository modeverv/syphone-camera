import Foundation
import CoreMediaIO

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private let deviceSource: CameraDeviceSource

    lazy var provider: CMIOExtensionProvider = {
        let p = CMIOExtensionProvider(source: self, clientQueue: nil)
        do {
            try p.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add virtual camera device: \(error)")
        }
        return p
    }()

    override init() {
        deviceSource = CameraDeviceSource(localizedName: CameraConstants.cameraName)
        super.init()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            result.name = "Syphon Camera"
        }
        if properties.contains(.providerManufacturer) {
            result.manufacturer = "Syphon Camera OSS"
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
}
