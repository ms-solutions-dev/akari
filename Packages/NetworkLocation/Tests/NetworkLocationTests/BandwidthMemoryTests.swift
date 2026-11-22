import Testing

@testable import NetworkLocation

@Suite("BandwidthMemory")
struct BandwidthMemoryTests {

    private let wifi = NetworkPath(kind: .wifi)
    private let cellular = NetworkPath(kind: .cellular, expensive: true)

    @Test("What was measured is there")
    func remember() {
        var memory = BandwidthMemory()
        memory.save(28.4, route: wifi, state: 3)
        #expect(memory.value(route: wifi, state: 3) == 28.4)
    }

    /// The core: **tied to the network path, not to the clock.** A measurement on the
    /// home Wi-Fi says nothing about the Wi-Fi in a café, and both are called "Wi-Fi".
    /// The counter from the network watch separates them.
    @Test("After a change the measurement no longer applies")
    func changeInvalidates() {
        var memory = BandwidthMemory()
        memory.save(28.4, route: wifi, state: 3)
        #expect(memory.value(route: wifi, state: 4) == nil)
    }

    @Test("A cellular value does not apply on Wi-Fi")
    func pathsSeparate() {
        var memory = BandwidthMemory()
        memory.save(1.2, route: cellular, state: 7)
        #expect(memory.value(route: wifi, state: 7) == nil)
        #expect(memory.value(route: cellular, state: 7) == 1.2)
    }

    /// Without a measurement **nothing is guessed**: "not measured yet" is the honest
    /// answer, and an invented number would be worse than none.
    @Test("Without a measurement there is no answer")
    func inventNothing() {
        let memory = BandwidthMemory()
        #expect(memory.usable(2.8, route: wifi, state: 1) == nil)
    }

    @Test("With a measurement it is compared")
    func comparison() {
        var memory = BandwidthMemory()
        memory.save(0.31, route: wifi, state: 1)
        #expect(memory.usable(2.8, route: wifi, state: 1) == false)
        #expect(memory.usable(0.2, route: wifi, state: 1) == true)
    }

    @Test("Zero is not remembered")
    func zeroNotRemembered() {
        var memory = BandwidthMemory()
        memory.save(0, route: wifi, state: 1)
        #expect(memory.value(route: wifi, state: 1) == nil)
    }
}
