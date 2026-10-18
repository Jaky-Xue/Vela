//
//  QRScannerView.swift
//  Vela
//
//  The 扫一扫 surface: the camera live, a frame to aim at, and the first QR
//  payload it reads handed to the shell.
//
//  Built on AVCaptureSession directly rather than VisionKit's data scanner:
//  the scanner's delivery proved unreliable on device, and the capture
//  pipeline is the one path every QR reader on the platform has run for a
//  decade — a session, a preview layer, a metadata output, and nothing else
//  to stand between the code and the callback.
//

import SwiftUI
import AVFoundation

/// The camera layer. Owns the session, the preview, and the permission ask;
/// reports what it can and cannot do through `onStatus`.
private struct CameraScanner: UIViewControllerRepresentable {
    var onRecognize: (String) -> Void
    var onStatus: (ScannerStatus) -> Void

    enum ScannerStatus {
        case running, denied, unavailable
    }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onRecognize = onRecognize
        controller.onStatus = onStatus
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onRecognize: ((String) -> Void)?
        var onStatus: ((ScannerStatus) -> Void)?

        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var sessionConfigured = false
        /// A code held in view is re-reported frame after frame; the first
        /// read wins until it leaves, so one scan is one action.
        private var lastPayload: String?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            startIfPossible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopSession()
        }

        /// SwiftUI can tear the layer down without walking its appearance
        /// callbacks, so the session's stop lives here too — a camera that
        /// keeps running after the scanner is gone is exactly the kind of
        /// quiet leak that reads as a broken scanner the next time.
        deinit {
            session.stopRunning()
        }

        private func stopSession() {
            if sessionConfigured {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.stopRunning()
                }
            }
        }

        private func startIfPossible() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndRun()
            case .notDetermined:
                // The ask happens on the controller's own appearance; the
                // answer comes back on an arbitrary queue and hops to main
                // to touch the view.
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.configureAndRun()
                        } else {
                            self.onStatus?(.denied)
                        }
                    }
                }
            default:
                onStatus?(.denied)
            }
        }

        private func configureAndRun() {
            guard !sessionConfigured else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onStatus?(.unavailable)
                return
            }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                onStatus?(.unavailable)
                return
            }
            // The output joins the session BEFORE its object types are named:
            // the available types are decided by the connection, and setting
            // them on an unconnected output raises an exception — the crash
            // the scanner opened with on a device whose permission was
            // already granted.
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            sessionConfigured = true
            onStatus?(.running)

            // Starting touches hardware; off the main thread, as the
            // documentation asks.
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            for object in metadataObjects {
                if let code = object as? AVMetadataMachineReadableCodeObject,
                   code.type == .qr,
                   let payload = code.stringValue,
                   payload != lastPayload {
                    lastPayload = payload
                    onRecognize?(payload)
                }
            }
        }
    }
}

/// The 扫一扫 layer: camera, a viewfinder frame, a hint line, and the ways
/// the camera can be unusable said plainly on screen.
struct QRScannerView: View {
    /// Called with the payload of a recognised QR code.
    var onRecognize: (String) -> Void
    var onClose: () -> Void

    @State private var status: CameraScanner.ScannerStatus = .running

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch status {
            case .running:
                CameraScanner(
                    onRecognize: onRecognize,
                    onStatus: { status = $0 }
                )
                .ignoresSafeArea()

            case .denied:
                permissionMessage(
                    systemImage: "lock.camera",
                    text: "相机权限被拒绝。请在系统设置 ▸ Vela 中允许访问相机。"
                )

            case .unavailable:
                permissionMessage(
                    systemImage: "camera.on.rectangle",
                    text: "此设备无法使用相机扫描。"
                )
            }

            VStack {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭扫码")
                    Spacer()
                }
                .padding(.horizontal, BrowserSpacing.regular)
                .padding(.top, BrowserSpacing.compact)

                Spacer()

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.75), lineWidth: 2)
                    .frame(width: 250, height: 250)

                Spacer()

                Text("将二维码对准取景框")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 64)
            }
            .allowsHitTesting(status == .running)
        }
    }

    private func permissionMessage(systemImage: String, text: String) -> some View {
        VStack(spacing: BrowserSpacing.compact) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
