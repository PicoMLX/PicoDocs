// AccessibilityAuditTests.swift
// Drop-in XCUITest file for automated accessibility auditing.
// Requires a platform that supports performAccessibilityAudit().
// The helper methods below skip gracefully on older deployment targets.
//
// Usage:
// 1. Add this file to your UI test target
// 2. Add navigation steps for each screen in your app
// 3. Run tests — failures indicate accessibility issues
//
// These tests use performAccessibilityAudit() to catch:
// - Missing accessibility labels
// - Low color contrast (WCAG thresholds)
// - Touch targets below 44x44pt
// - Text that doesn't scale with Dynamic Type
// - Clipped or truncated text
// - Incorrect accessibility traits

import XCTest

final class AccessibilityAuditTests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    // MARK: - Full Audit (All Checks)

    /// Audits the launch screen with all accessibility checks.
    /// Add one test method per key screen in your app.
    func testLaunchScreenAccessibility() throws {
        try performAudit()
    }

    // MARK: - Per-Screen Audits
    //
    // Copy this pattern for each screen. Navigate to the screen,
    // then run the audit.
    //
    // func testSettingsScreenAccessibility() throws {
    //     app.tabBars.buttons["Settings"].tap()
    //     try performAudit()
    // }
    //
    // func testProfileScreenAccessibility() throws {
    //     app.tabBars.buttons["Profile"].tap()
    //     try performAudit()
    // }

    // MARK: - Filtered Audits

    /// Contrast and labels only — the two most common failures.
    func testContrastAndLabels() throws {
        try performAudit([.contrast, .sufficientElementDescription])
    }

    /// Touch targets and element detection.
    func testHitRegionsAndDetection() throws {
        try performAudit([.hitRegion, .elementDetection])
    }

    /// Dynamic Type scaling and text clipping.
    func testDynamicTypeSupport() throws {
        try performAudit([.dynamicType, .textClipped])
    }

    // MARK: - Audit with Known Issue Exclusions

    /// Full audit that ignores specific known issues.
    /// Replace the example exclusion with your own.
    func testAuditWithExclusions() throws {
        try performAudit(.all) { issue in
            // Example: ignore contrast issues on branded splash logo
            // if issue.auditType == .contrast,
            //    issue.element?.identifier == "splashLogo" {
            //     return true  // true = ignore this issue
            // }
            return false  // false = fail on this issue
        }
    }

    // MARK: - Multi-Screen Regression Test

    /// Navigates through key screens and audits each one.
    /// Customize the navigation steps for your app's tab bar or flow.
    func testFullAppAccessibilityRegression() throws {
        // Screen 1: Launch / Home
        try performAudit()

        // Screen 2: Navigate to second tab (customize for your app)
        // app.tabBars.buttons["Search"].tap()
        // try performAudit()

        // Screen 3: Navigate to third tab
        // app.tabBars.buttons["Settings"].tap()
        // try performAudit()
    }

    private func performAudit(
        _ auditTypes: XCUIAccessibilityAuditType = .all
    ) throws {
        try requireAccessibilityAuditSupport()
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
            try app.performAccessibilityAudit(for: auditTypes)
        }
    }

    private func performAudit(
        _ auditTypes: XCUIAccessibilityAuditType = .all,
        issueHandler: @escaping (XCUIAccessibilityAuditIssue) throws -> Bool
    ) throws {
        try requireAccessibilityAuditSupport()
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
            try app.performAccessibilityAudit(for: auditTypes, issueHandler)
        }
    }

    private func requireAccessibilityAuditSupport() throws {
        guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) else {
            throw XCTSkip(
                "performAccessibilityAudit() requires iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, or visionOS 1+."
            )
        }
    }
}
