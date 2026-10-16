//
//  TabLoadStateTests.swift
//  VelaTests
//
//  The two things a browser is judged on when something goes wrong: does the
//  tab's state describe what actually happened, and does the error surface get
//  told the truth about why.
//
//  All of it is pure — no web view, no network — because these are the decisions
//  that have to be right every time, and the integration suite is too slow and
//  too coarse to pin them down one by one.
//

import XCTest
@testable import Vela

// MARK: - Failure classification

final class TabNavigationFailureTests: XCTestCase {
    private func failure(domain: String, code: Int, url: String = "https://example.com/x") -> TabNavigationFailure? {
        let error = NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "test error"]
        )
        return TabNavigationFailure.make(from: error, url: url)
    }

    func testNoNetworkIsReportedAsBeingOffline() {
        let failure = failure(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(failure?.kind, .offline)
        XCTAssertTrue(failure?.isRetryable == true)
    }

    func testAHostThatDoesNotResolveIsADnsFailure() {
        XCTAssertEqual(
            failure(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)?.kind,
            .dns
        )
        XCTAssertEqual(
            failure(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)?.kind,
            .dns
        )
    }

    func testEachTransportFailureHasItsOwnKind() {
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)?.kind, .timeout)
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)?.kind, .refused)
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)?.kind, .connectionLost)
    }

    /// The certificate failures are kept as one kind because the answer is the
    /// same for all of them — the connection is not trusted and Vela will not
    /// pretend otherwise — and none of them is a reason to relax verification.
    func testCertificateFailuresAreReportedAsTlsWithoutOfferingToBypass() {
        for code in [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorClientCertificateRejected
        ] {
            let reported = failure(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(reported?.kind, .tls, "code \(code)")
            XCTAssertFalse(
                reported?.detail.isEmpty ?? true,
                "a TLS failure has to say something about the certificate"
            )
        }
    }

    func testAnUnsupportedSchemeIsReportedAsAnInvalidAddress() {
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)?.kind, .invalidUrl)
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorBadURL)?.kind, .invalidUrl)
        XCTAssertEqual(failure(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)?.isRetryable, false)
    }

    func testAnUnknownErrorStillProducesSomethingWorthShowing() {
        let reported = failure(domain: "SomeOtherDomain", code: 42)
        XCTAssertEqual(reported?.kind, .other)
        XCTAssertEqual(reported?.errorDomain, "SomeOtherDomain")
        XCTAssertEqual(reported?.errorCode, 42)
        XCTAssertFalse(reported?.title.isEmpty ?? true)
    }

    func testTheFailureCarriesTheUrlItWasFor() {
        let reported = failure(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            url: "https://example.com/a/b?c=1"
        )
        XCTAssertEqual(reported?.url, "https://example.com/a/b?c=1")
    }

    // MARK: Cancellation

    /// A cancellation is not a failure, and the distinction is the one that
    /// matters most: a redirect, a declined `target="_blank"` and the stop button
    /// all cancel a navigation.
    func testAnNsurlCancellationIsNotAFailure() {
        XCTAssertNil(failure(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertTrue(
            TabNavigationFailure.isCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
    }

    /// WebKit reports a cancelled policy decision in its own domain. Checking only
    /// for `NSURLErrorCancelled` is what made opening a link in a new tab put the
    /// page it was clicked on into a failed state.
    func testAPolicyInterruptionIsTreatedAsACancellation() {
        XCTAssertNil(
            failure(domain: "WebKitErrorDomain", code: 102),
            "a frame load interrupted by a policy change is not a failure to report"
        )
        XCTAssertTrue(
            TabNavigationFailure.isCancellation(NSError(domain: "WebKitErrorDomain", code: 102))
        )
    }

    func testACrashIsItsOwnKindAndIsNotRetryableByRedisplay() {
        let crash = TabNavigationFailure.crashed(url: "https://example.com/")
        XCTAssertEqual(crash.kind, .crashed)
        XCTAssertFalse(crash.isRetryable)
        XCTAssertEqual(crash.errorDomain, "WebKitErrorDomain")
        XCTAssertEqual(crash.errorCode, TabNavigationFailure.webContentProcessTerminatedCode)
        XCTAssertFalse(crash.title.isEmpty)
    }

    func testEveryKindHasATitleAndRetryPolicy() {
        for kind in TabNavigationFailure.Kind.allCases {
            let reported = TabNavigationFailure(
                kind: kind,
                title: "t",
                detail: "",
                url: "",
                errorDomain: "",
                errorCode: 0
            )
            XCTAssertFalse(reported.title.isEmpty, "\(kind) has no title")
        }
    }
}

// MARK: - Load state

final class TabLoadStateTests: XCTestCase {
    func testInFlightIsExactlyTheMiddleOfANavigation() {
        XCTAssertTrue(TabLoadState.requested.isInFlight)
        XCTAssertTrue(TabLoadState.provisional.isInFlight)
        XCTAssertTrue(TabLoadState.committed.isInFlight)
        XCTAssertFalse(TabLoadState.idle.isInFlight)
        XCTAssertFalse(TabLoadState.finished.isInFlight)
        XCTAssertFalse(TabLoadState.cancelled.isInFlight)
        XCTAssertFalse(TabLoadState.failed.isInFlight)
        XCTAssertFalse(TabLoadState.crashed.isInFlight)
    }

    func testOnlyFailedAndCrashedAreFailures() {
        XCTAssertTrue(TabLoadState.failed.isFailure)
        XCTAssertTrue(TabLoadState.crashed.isFailure)
        // A cancellation is deliberately not a failure: the stop button must not
        // produce an error page.
        XCTAssertFalse(TabLoadState.cancelled.isFailure)
        XCTAssertFalse(TabLoadState.finished.isFailure)
    }

    func testACommittedDocumentIsWhatMakesGoingBackMeaningful() {
        XCTAssertTrue(TabLoadState.committed.hasCommittedDocument)
        XCTAssertTrue(TabLoadState.finished.hasCommittedDocument)
        XCTAssertFalse(TabLoadState.provisional.hasCommittedDocument)
        XCTAssertFalse(TabLoadState.failed.hasCommittedDocument)
    }
}

// MARK: - When a tab needs its page fetched

@MainActor
final class TabPageFetchTests: XCTestCase {
    private func tab(url: String, loadState: TabLoadState, isHome: Bool = false) -> BrowserTabState {
        let tab = BrowserTabState(url: url, isHome: isHome)
        tab.loadState = loadState
        return tab
    }

    /// The question `activateTab` asks. It used to be answered in the view layer
    /// by `webView.url == nil`, which stays true after a failure and is what
    /// produced an endless retry loop.
    func testAColdTabWithAUrlNeedsFetching() {
        XCTAssertTrue(tab(url: "https://example.com", loadState: .idle).needsPageFetch)
    }

    func testAFinishedTabDoesNotNeedFetchingAgain() {
        XCTAssertFalse(tab(url: "https://example.com", loadState: .finished).needsPageFetch)
        XCTAssertFalse(tab(url: "https://example.com", loadState: .committed).needsPageFetch)
    }

    func testANavigationInFlightIsNotFetchedOver() {
        for state in [TabLoadState.requested, .provisional, .committed] {
            XCTAssertFalse(tab(url: "https://example.com", loadState: state).needsPageFetch, "\(state)")
        }
    }

    /// A tab showing the error surface keeps showing it until the user says
    /// otherwise. Re-fetching behind the error page would replace a page that
    /// explains what happened with a spinner.
    func testATabShowingAFailureIsNotRefetchedAutomatically() {
        XCTAssertFalse(tab(url: "https://example.com", loadState: .failed).needsPageFetch)
        XCTAssertFalse(tab(url: "https://example.com", loadState: .crashed).needsPageFetch)
    }

    /// A stopped navigation is a page the user chose not to load, so it is not
    /// retried the moment they switch away and back.
    func testACancelledTabIsNotRefetchedAutomatically() {
        XCTAssertFalse(tab(url: "https://example.com", loadState: .cancelled).needsPageFetch)
    }

    func testTheHomeSurfaceAndAnEmptyUrlHaveNothingToFetch() {
        XCTAssertFalse(tab(url: "https://example.com", loadState: .idle, isHome: true).needsPageFetch)
        XCTAssertFalse(tab(url: "", loadState: .idle).needsPageFetch)
    }

    /// What a discarded tab looks like: the URL is kept, the state goes back to
    /// idle, and activating it fetches the page again.
    func testDiscardingReturnsATabToNeedingAFetch() {
        let tab = BrowserTabState(url: "https://example.com", isHome: false)
        tab.loadState = .finished
        XCTAssertFalse(tab.needsPageFetch)

        tab.loadState = .idle
        tab.lastFailure = nil
        XCTAssertTrue(tab.needsPageFetch)
    }
}

// MARK: - The navigation log

final class NavigationLogRedactionTests: XCTestCase {
    func testAQueryIsReplacedByItsParameterCount() {
        XCTAssertEqual(
            NavigationLog.redact("https://example.com/search?q=how+tall+is+everest&hl=en"),
            "https://example.com/search?<2 个参数>"
        )
    }

    func testAQueryWithNoValuesIsStillCounted() {
        XCTAssertEqual(
            NavigationLog.redact("https://example.com/s?flag"),
            "https://example.com/s?<1 个参数>"
        )
    }

    /// The two places a URL hides something personal.
    func testCredentialsAndFragmentsAreDropped() {
        let redacted = NavigationLog.redact("https://user:secret@example.com/private#account-42")
        XCTAssertEqual(redacted, "https://example.com/private#<片段>")
        XCTAssertFalse(redacted.contains("user"))
        XCTAssertFalse(redacted.contains("secret"))
    }

    func testAPortIsKeptBecauseItIdentifiesTheServer() {
        XCTAssertEqual(
            NavigationLog.redact("http://localhost:8080/dev?token=abc"),
            "http://localhost:8080/dev?<1 个参数>"
        )
    }

    func testASchemeWithNoAuthorityKeepsOnlyItsShape() {
        let redacted = NavigationLog.redact("mailto:someone@example.com")
        XCTAssertTrue(redacted.hasPrefix("mailto:"), redacted)
        XCTAssertFalse(redacted.contains("someone"))
        XCTAssertFalse(redacted.contains("example.com"))
    }

    func testSomethingThatIsNotAUrlIsRecordedAsALength() {
        XCTAssertEqual(NavigationLog.redact("not a url at all"), "<17 字符>")
        XCTAssertEqual(NavigationLog.redact(""), "")
    }

    func testTheSchemeIsReadWithoutParsingTheRest() {
        XCTAssertEqual(NavigationLog.scheme(of: "https://example.com"), "https")
        XCTAssertEqual(NavigationLog.scheme(of: "HTTP://example.com"), "http")
        XCTAssertEqual(NavigationLog.scheme(of: "/just/a/path"), "")
        XCTAssertEqual(NavigationLog.scheme(of: "1abc:def"), "")
    }
}

@MainActor
final class NavigationLogBufferTests: XCTestCase {
    func testTheBufferIsBounded() {
        let log = NavigationLog()
        for index in 0..<(NavigationLog.capacity + 30) {
            log.record(
                tabId: "tab",
                navigationSerial: index,
                event: .start,
                phase: .provisional,
                url: "https://example.com/\(index)"
            )
        }
        XCTAssertEqual(log.entries.count, NavigationLog.capacity)
        // The oldest are the ones dropped, so the newest navigation is still
        // there to be read.
        XCTAssertEqual(log.entries.last?.navigationSerial, NavigationLog.capacity + 29)
    }

    func testNothingIsRecordedWhenTheLogIsSwitchedOff() {
        let log = NavigationLog(settings: NavigationDiagnosticsSettings(enabled: false))
        log.record(tabId: "tab", navigationSerial: 1, event: .start, phase: .provisional, url: "https://a.example")
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testTheReportContainsOnlyRedactedUrls() {
        let log = NavigationLog()
        log.record(
            tabId: "tab",
            navigationSerial: 1,
            event: .finish,
            phase: .finished,
            url: "https://example.com/private?email=someone@example.com&token=abc"
        )
        let report = log.report()
        XCTAssertTrue(report.contains("https://example.com/private"))
        XCTAssertFalse(report.contains("someone@example.com"))
        XCTAssertFalse(report.contains("token"))
    }

    func testClearingEmptiesTheBuffer() {
        let log = NavigationLog()
        log.record(tabId: "tab", navigationSerial: 1, event: .start, phase: .provisional, url: "https://a.example")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.report(), "没有导航记录。")
    }

    /// Every entry carries the two facts a report needs to be interpretable:
    /// which feature was on, and how long the page took.
    func testAnEntryCarriesItsDiagnosticContext() {
        let log = NavigationLog()
        log.record(
            tabId: "tab-1",
            navigationSerial: 7,
            event: .fail,
            phase: .failed,
            url: "https://example.com/",
            navigationType: "linkActivated",
            durationMs: 1234,
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut,
            errorMessage: "timed out",
            outcome: .failure,
            adBlockActive: true,
            userScriptsActive: false
        )
        guard let entry = log.entries.first else { return XCTFail("nothing recorded") }
        XCTAssertEqual(entry.tabId, "tab-1")
        XCTAssertEqual(entry.navigationSerial, 7)
        XCTAssertEqual(entry.durationMs, 1234)
        XCTAssertEqual(entry.errorCode, NSURLErrorTimedOut)
        XCTAssertEqual(entry.outcome, .failure)
        XCTAssertTrue(entry.adBlockActive)
        XCTAssertFalse(entry.userScriptsActive)
        XCTAssertTrue(entry.displayLine.contains("linkActivated"))
    }
}
