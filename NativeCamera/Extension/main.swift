import CoreMediaIO
import Foundation

let clientQueue = DispatchQueue(label: "com.dream-jack.syphoncamera.extension", qos: .userInteractive)
let providerSource = ZeroCopyCameraProviderSource(clientQueue: clientQueue)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
