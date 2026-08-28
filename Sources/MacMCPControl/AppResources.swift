import Foundation

enum AppResources {
    static func ngrokExecutable(in appBundle: Bundle = .main) -> URL? {
        if appBundle.bundleURL.pathExtension == "app" {
            // SwiftPM's generated accessor can search beside the .app rather than inside
            // Contents/Resources. Do not evaluate Bundle.module in a packaged app: it traps
            // before a fallback can run when the build-machine path is unavailable.
            guard let bundleURL = appBundle.url(forResource: "MacMCPControl_MacMCPControl", withExtension: "bundle"),
                  let resources = Bundle(url: bundleURL) else { return nil }
            return resources.url(forResource: "ngrok", withExtension: nil)
        }
        return Bundle.module.url(forResource: "ngrok", withExtension: nil)
    }
}
