import Foundation
import CoreMediaIO

let providerSource = CameraProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
