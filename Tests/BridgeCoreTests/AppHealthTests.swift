import Foundation
import Testing

@testable import BridgeCore

@Suite struct AppHealthTests {
    @Test func includesAppAndStatus() {
        let result = buildHealthResult(
            app: "test-bridge",
            status: "ok",
            details: [:]
        )
        #expect(result["app"] as? String == "test-bridge")
        #expect(result["status"] as? String == "ok")
    }

    @Test func includesDetails() {
        let result = buildHealthResult(
            app: "mail-bridge",
            status: "ok",
            details: ["appInstalled": true, "appRunning": false]
        )
        #expect(result["appInstalled"] as? Bool == true)
        #expect(result["appRunning"] as? Bool == false)
        #expect(result["app"] as? String == "mail-bridge")
        #expect(result["status"] as? String == "ok")
    }

    @Test func errorStatus() {
        let result = buildHealthResult(
            app: "things-bridge",
            status: "error",
            details: ["appInstalled": false, "appRunning": false]
        )
        #expect(result["status"] as? String == "error")
        #expect(result["appInstalled"] as? Bool == false)
    }

    @Test func accessFlag() {
        let result = buildHealthResult(
            app: "calendar-bridge",
            status: "ok",
            details: ["hasAccess": true]
        )
        #expect(result["hasAccess"] as? Bool == true)
        #expect(result["status"] as? String == "ok")
    }

    @Test func detailsMergeWithBaseKeys() {
        let result = buildHealthResult(
            app: "test-bridge",
            status: "ok",
            details: ["extra": "value"]
        )
        #expect(result.count == 3)
        #expect(result["extra"] as? String == "value")
    }
}
