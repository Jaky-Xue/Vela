//
//  BrowserKernel.swift
//  Vela
//
//  The seam between the browser and the engine that renders its pages.
//
//  Today there is one kernel: WebKit, the only engine iOS allows inside an app.
//  The protocol exists anyway, because everything above this line — tabs, the
//  shell, the reader, the vault — should be able to survive an engine that
//  brings more than WebKit can express. A kernel owns the creation and
//  preparation of a tab's content view, which is the point where an engine
//  installs its own message handlers, scripts and media bridges (WebRTC capture
//  being the reason this seam was added).
//
//  The WebKit kernel deliberately does nothing extra in `prepare`: the
//  browser's existing bridges are installed by `BrowserWebCoordinator`, and a
//  kernel that also installed them would double every handler. A future kernel
//  replaces the coordinator's content view rather than layering on top of it.
//

import Foundation
import WebKit

// MARK: - Capabilities

/// What a kernel can do, advertised rather than assumed.
///
/// The shell does not branch on these yet; they are the contract a second
/// kernel has to state when it registers, and the settings and diagnostics
/// screens can read them to describe the engine in force.
public struct BrowserKernelCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Injecting a document-start or document-end script, and receiving its
    /// messages.
    public static let scriptInjection = BrowserKernelCapabilities(rawValue: 1 << 0)
    /// Compiling declarative content rules for ad and tracker blocking.
    public static let contentBlocking = BrowserKernelCapabilities(rawValue: 1 << 1)
    /// Camera and microphone capture that a page can request.
    public static let mediaCapture = BrowserKernelCapabilities(rawValue: 1 << 2)
    /// A bridge through which a page's media session can be observed and
    /// controlled — the extension point for WebRTC work.
    public static let webRTCControl = BrowserKernelCapabilities(rawValue: 1 << 3)
    /// The ability to install a document-start policy over WebRTC. This is what
    /// `WebRTCGuard` provides on the WebKit kernel.
    public static let webRTCLeakProtection = BrowserKernelCapabilities(rawValue: 1 << 5)
    /// A snapshot of the rendered page, used by the tab overview.
    public static let pageSnapshot = BrowserKernelCapabilities(rawValue: 1 << 4)
}

// MARK: - Descriptor

/// A kernel's identity and advertised abilities, as the UI shows them.
public struct BrowserKernelDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    /// What the engine is, in the user's terms: "WebKit" today.
    public var engineDescription: String
    public var capabilities: BrowserKernelCapabilities

    public init(
        id: String,
        displayName: String,
        engineDescription: String,
        capabilities: BrowserKernelCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.engineDescription = engineDescription
        self.capabilities = capabilities
    }
}

// MARK: - Kernel

/// An engine that can host one tab's page.
///
/// Everything the browser needs from an engine at tab-creation time goes
/// through this protocol. The rest of the app talks to the resulting
/// `WKWebView` — a deliberate compromise of this build: a non-WebKit kernel
/// needs a content-view abstraction before it can replace this method, but a
/// WebKit-compatible kernel (a subclass carrying WebRTC bridges, a privacy
/// hardening layer) can plug in here today without touching a single tab.
@MainActor
public protocol BrowserKernel: AnyObject {
    var descriptor: BrowserKernelDescriptor { get }

    /// Creates the view a tab will render its page in. The caller has already
    /// built the configuration; a kernel may return a subclass or wrap it.
    func makeWebView(for tab: BrowserTabState, configuration: WKWebViewConfiguration) -> WKWebView

    /// Installs whatever the kernel owns after the view exists: message
    /// handlers, media bridges, diagnostics. The default implementation does
    /// nothing, so a plain kernel has no boilerplate.
    func prepare(_ webView: WKWebView, for tab: BrowserTabState)
}

extension BrowserKernel {
    public func prepare(_ webView: WKWebView, for tab: BrowserTabState) {}
}

// MARK: - WebKit

/// The kernel this build ships: WebKit, unmodified.
@MainActor
public final class WebKitKernel: BrowserKernel {
    public init() {}

    public var descriptor: BrowserKernelDescriptor {
        BrowserKernelDescriptor(
            id: "webkit",
            displayName: "WebKit",
            engineDescription: "WebKit",
            capabilities: [
                .scriptInjection,
                .contentBlocking,
                .mediaCapture,
                .webRTCLeakProtection,
                .pageSnapshot
            ]
        )
    }

    public func makeWebView(
        for tab: BrowserTabState,
        configuration: WKWebViewConfiguration
    ) -> WKWebView {
        WKWebView(frame: .zero, configuration: configuration)
    }
}

// MARK: - Registry

/// The kernels this build knows about, and which one is in force.
///
/// A future build registers its kernel before the first tab is created. The
/// registry is the only mutable piece of the seam; the content path asks it
/// once per web view, so registering a kernel is enough to try it.
@MainActor
public final class BrowserKernelRegistry {
    public private(set) var active: any BrowserKernel

    private var kernels: [String: any BrowserKernel]

    public init() {
        let webKit = WebKitKernel()
        self.kernels = [webKit.descriptor.id: webKit]
        self.active = webKit
    }

    /// Registers a kernel without activating it.
    public func register(_ kernel: any BrowserKernel) {
        kernels[kernel.descriptor.id] = kernel
    }

    /// Makes a registered kernel the one new tabs are built with.
    @discardableResult
    public func activate(id: String) -> Bool {
        guard let kernel = kernels[id] else { return false }
        active = kernel
        return true
    }

    public var descriptors: [BrowserKernelDescriptor] {
        kernels.values.map { $0.descriptor }.sorted { $0.displayName < $1.displayName }
    }
}
