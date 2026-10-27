// Adapted from the installed Xcode Camera Extension template.

import Foundation
import CoreMediaIO

let providerSource = ProbeCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
