@testable import HappyCore
import HappyWire
import XCTest

/// The composer's context meter: desktop's `contextGaugeDerive` for the
/// numbers, and `ContextMeter` for the colour, the notch and the readout,
/// over the specimens of desktop's ContextMeterPage.
final class AgentContextGaugeTests: XCTestCase {
    private let catalog = ModelCatalog(response: Data("""
    {"config": {
        "defaults": {"providerId": "claude", "modelId": "anthropic/opus-5", "effort": "medium", "permissionMode": "auto"},
        "models": {
            "anthropic/opus-5": {"name": "Opus 5 1M", "efforts": ["medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 1000000, "autoCompactWindow": 400000},
            "anthropic/sonnet-5": {"name": "Sonnet 5", "efforts": ["medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 200000},
            "custom/thing": {"name": "Thing", "efforts": ["medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": null},
            "anthropic/odd": {"name": "Odd", "efforts": ["medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 100000, "autoCompactWindow": 100000}
        },
        "providers": {
            "claude": {"type": "claude", "enabled": true, "models": [
                {"id": "anthropic/opus-5", "enabled": true}, {"id": "anthropic/sonnet-5", "enabled": true},
                {"id": "custom/thing", "enabled": true}, {"id": "anthropic/odd", "enabled": true}]}
        }
    }}
    """.utf8))!

    private func mode(_ modelId: String) -> AgentWire.Mode {
        AgentWire.Mode(providerId: "claude", modelId: modelId, effort: "medium", serviceTier: nil, permissionMode: "auto")
    }

    private func context(_ tokens: Double, window: Double? = nil, model: String? = "anthropic/opus-5", approximate: Bool = false) -> AgentWire.ContextUsage {
        AgentWire.ContextUsage(approximate: approximate, contextTokens: tokens, contextWindow: window, modelId: model, providerId: "claude")
    }

    // MARK: Deriving

    /// Before the first measurement, the selection's declared window shows
    /// empty, so the meter is there to be found.
    func testBeforeAMeasurementTheSelectedWindowShowsUnmeasured() {
        let gauge = AgentContextGauge.derive(catalog: catalog, context: nil, selection: mode("anthropic/opus-5"))
        XCTAssertEqual(gauge, AgentContextGauge(usedTokens: 0, totalTokens: 1_000_000, compactTokens: 400_000, approximate: false, measured: false))
        XCTAssertEqual(gauge?.fraction, 0)
        XCTAssertEqual(gauge?.percent, 0)
        // A model without a known window has no meter.
        XCTAssertNil(AgentContextGauge.derive(catalog: catalog, context: nil, selection: mode("custom/thing")))
        XCTAssertNil(AgentContextGauge.derive(catalog: catalog, context: nil, selection: nil))
        XCTAssertNil(AgentContextGauge.derive(catalog: nil, context: nil, selection: mode("anthropic/opus-5")))
    }

    func testAMeasurementUsesItsOwnWindowElseItsModels() {
        let reported = AgentContextGauge.derive(catalog: catalog, context: context(84_000, window: 200_000, model: "anthropic/sonnet-5"), selection: mode("anthropic/opus-5"))
        XCTAssertEqual(reported, AgentContextGauge(usedTokens: 84_000, totalTokens: 200_000))
        let modelWindow = AgentContextGauge.derive(catalog: catalog, context: context(120_000), selection: nil)
        XCTAssertEqual(modelWindow, AgentContextGauge(usedTokens: 120_000, totalTokens: 1_000_000, compactTokens: 400_000))
        // Past the window it is the window; no window known is no meter.
        XCTAssertEqual(AgentContextGauge.derive(catalog: catalog, context: context(250_000, window: 200_000), selection: nil)?.usedTokens, 200_000)
        XCTAssertNil(AgentContextGauge.derive(catalog: catalog, context: context(5_000, model: "custom/thing"), selection: mode("custom/thing")))
        XCTAssertNil(AgentContextGauge.derive(catalog: catalog, context: context(5_000, model: nil), selection: mode("anthropic/opus-5")))
        XCTAssertEqual(AgentContextGauge.derive(catalog: catalog, context: context(5_000, window: 64_000, model: nil, approximate: true), selection: nil),
                       AgentContextGauge(usedTokens: 5_000, totalTokens: 64_000, approximate: true))
    }

    /// A compaction point at or past the window is no point at all.
    func testACompactionPointAtTheWindowIsNone() {
        let odd = AgentContextGauge.derive(catalog: catalog, context: nil, selection: mode("anthropic/odd"))
        XCTAssertNil(odd?.compactTokens)
        XCTAssertEqual(odd?.compactFraction, 0.75)
    }

    // MARK: The meter

    /// ContextMeterPage's specimens: ample, compaction due, and the
    /// three-quarter notch without a published point.
    func testTheSpecimensTones() {
        XCTAssertEqual(AgentContextGauge(usedTokens: 16_000, totalTokens: 200_000).tone, .ample)
        XCTAssertEqual(AgentContextGauge(usedTokens: 120_000, totalTokens: 1_000_000, compactTokens: 400_000).tone, .ample)
        XCTAssertEqual(AgentContextGauge(usedTokens: 330_000, totalTokens: 1_000_000, compactTokens: 400_000).tone, .compact)
        XCTAssertEqual(AgentContextGauge(usedTokens: 405_000, totalTokens: 1_000_000, compactTokens: 400_000, approximate: true).tone, .critical)
        XCTAssertEqual(AgentContextGauge(usedTokens: 158_000, totalTokens: 200_000).tone, .critical)
        XCTAssertEqual(AgentContextGauge(usedTokens: 200_000, totalTokens: 200_000).tone, .critical)
        // The warning colour within a fifth of the point: 0.6 of a 0.75 notch,
        // computed as desktop computes it, where 0.75 × 0.8 is a hair over 0.6.
        XCTAssertEqual(AgentContextGauge(usedTokens: 120_000, totalTokens: 200_000).tone, .ample)
        XCTAssertEqual(AgentContextGauge(usedTokens: 120_001, totalTokens: 200_000).tone, .compact)
        XCTAssertEqual(AgentContextGauge(usedTokens: 149_999, totalTokens: 200_000).tone, .compact)
        XCTAssertEqual(AgentContextGauge(usedTokens: 150_000, totalTokens: 200_000).tone, .critical)
        // Unmeasured is empty, so quiet.
        XCTAssertEqual(AgentContextGauge(usedTokens: 190_000, totalTokens: 200_000, measured: false).tone, .ample)
    }

    func testTheNotchAndThePercent() {
        let gauge = AgentContextGauge(usedTokens: 330_000, totalTokens: 1_000_000, compactTokens: 400_000)
        XCTAssertEqual(gauge.compactFraction, 0.4)
        XCTAssertEqual(gauge.fraction, 0.33)
        XCTAssertEqual(gauge.percent, 33)
        XCTAssertEqual(AgentContextGauge(usedTokens: 1_005, totalTokens: 200_000).percent, 1)
        XCTAssertEqual(AgentContextGauge(usedTokens: 0, totalTokens: 0).fraction, 0)
    }

    /// `tokensFormat`.
    func testTokens() {
        XCTAssertEqual(AgentContextGauge.tokens(0), "0")
        XCTAssertEqual(AgentContextGauge.tokens(950), "950")
        XCTAssertEqual(AgentContextGauge.tokens(1_000), "1k")
        XCTAssertEqual(AgentContextGauge.tokens(1_250), "1.3k")
        XCTAssertEqual(AgentContextGauge.tokens(16_000), "16k")
        XCTAssertEqual(AgentContextGauge.tokens(84_321), "84.3k")
        XCTAssertEqual(AgentContextGauge.tokens(99_960), "100k")
        XCTAssertEqual(AgentContextGauge.tokens(158_000), "158k")
        XCTAssertEqual(AgentContextGauge.tokens(200_000), "200k")
        XCTAssertEqual(AgentContextGauge.tokens(999_499), "999k")
        XCTAssertEqual(AgentContextGauge.tokens(1_000_000), "1M")
        XCTAssertEqual(AgentContextGauge.tokens(1_050_000), "1.1M")
    }

    // MARK: The wire

    func testTheBootstrapCarriesTheMeasurement() throws {
        let bootstrap = try JSONDecoder().decode(AgentWire.Bootstrap.self, from: Data("""
        {"agent": {"id": "a", "workspaceId": "w", "status": "idle"},
         "context": {"approximate": false, "contextTokens": 84000, "contextWindow": 200000, "modelId": "anthropic/sonnet-5", "providerId": "claude"}}
        """.utf8))
        XCTAssertEqual(bootstrap.context, AgentWire.ContextUsage(contextTokens: 84_000, contextWindow: 200_000, modelId: "anthropic/sonnet-5", providerId: "claude"))
        let none = try JSONDecoder().decode(AgentWire.Bootstrap.self, from: Data(#"{"agent": {"id": "a", "workspaceId": "w", "status": "idle"}, "context": null}"#.utf8))
        XCTAssertNil(none.context)
        let custom = try JSONDecoder().decode(AgentWire.ContextUsage.self, from: Data(#"{"approximate": true, "contextTokens": 12, "contextWindow": null, "modelId": null, "providerId": "x"}"#.utf8))
        XCTAssertNil(custom.contextWindow)
        XCTAssertTrue(custom.approximate)
    }
}
