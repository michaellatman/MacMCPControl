import XCTest
@testable import MacMCPControl

final class AppResourcesTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.macmcpcontrol.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return app
    }

    func testPackagedAppFindsFlatAndStructuredResourceBundles() throws {
        for structured in [false, true] {
            let app = try fixture()
            let bundle = app.appendingPathComponent("Contents/Resources/MacMCPControl_MacMCPControl.bundle")
            let resources = structured ? bundle.appendingPathComponent("Contents/Resources") : bundle
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            if structured {
                let info = ["CFBundleIdentifier": "com.macmcpcontrol.fixture.resources", "CFBundlePackageType": "BNDL"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            }
            let executable = resources.appendingPathComponent("ngrok")
            try Data("fixture".utf8).write(to: executable)
            let result = AppResources.ngrokExecutable(in: try XCTUnwrap(Bundle(url: app)))
            XCTAssertEqual(result?.resolvingSymlinksInPath(), executable.resolvingSymlinksInPath())
        }
    }

    func testMissingPackagedResourcesDoNotFallBackToBuildMachine() throws {
        let app = try fixture()
        XCTAssertNil(AppResources.ngrokExecutable(in: try XCTUnwrap(Bundle(url: app))))
    }
}
