import Testing
@testable import LeverageMCP

struct ActivityWindowTests {
    @Test func activityLastsExactlyTenMinutesAndASecondCallRestartsIt() {
        var window = ActivityWindow()
        #expect(!window.isOpen(at: .seconds(1)))
        window.recordCall(at: .seconds(2))
        #expect(window.isOpen(at: .seconds(2)))
        #expect(window.isOpen(at: .seconds(601)))
        #expect(!window.isOpen(at: .seconds(602)))
        window.recordCall(at: .seconds(620))
        #expect(window.isOpen(at: .seconds(620)))
        #expect(window.isOpen(at: .seconds(1219)))
        #expect(!window.isOpen(at: .seconds(1220)))
    }
}
