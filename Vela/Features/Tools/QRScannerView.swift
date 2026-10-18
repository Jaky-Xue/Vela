//
//  QRScannerView.swift
//  Vela
//
//  The 扫一扫 surface: the camera live, a frame to aim at, and the first QR
//  payload it reads handed to the shell.
//
//  It rides VisionKit's `DataScannerViewController` rather than AVCapture:
//  the system scanner brings tracking and the permission plumbing already
//  tuned, and the browser's job is only to react to what it reads. The
//  representable is a view-CONTROLLER one — the data scanner is a view
//  controller, and wrapping it as a view representable fails to compile.
//

import SwiftUI
import VisionKit
import AVFoundation

/// The camera layer — a representable over the system data scanner.
private struct CameraScanner: UIViewControllerRepresentable {
    var onRecognize: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognize: onRecognize)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRecognize: (String) -> Void
        /// A code held in view is re-reported frame after frame; the first
        /// read wins until it leaves, so one scan is one action.
        private var lastPayload: String?

        init(onRecognize: @escaping (String) -> Void) {
            self.onRecognize = onRecognize
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd items: [RecognizedItem]) {
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = String(data: barcode.payload, encoding: .utf8),
                   payload != lastPayload {
                    lastPayload = payload
                    onRecognize(payload)
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove items: [RecognizedItem]) {
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = String(data: barcode.payload, encoding: .utf8),
                   payload == lastPayload {
                    lastPayload = nil
                }
            }
        }
    }
}

/// The 扫一扫 layer: camera, a hint line, and the ways the camera can be
/// unusable said plainly on screen.
struct QRScannerView: View {
    /// Called with the payload of a recognised QR code.
    var onRecognize: (String) -> Void
    var onClose: () -> Void

    @State private var permission: CameraPermission = .notDetermined

    private enum CameraPermission {
        case notDetermined, granted, denied, unavailable
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch permission {
            case .notDetermined, .granted:
                // `notDetermined` shows the camera anyway: starting the
                // scanner is what raises the system's own prompt, and the
                // answer arrives as the next authorization report.
                CameraScanner(onRecognize: onRecognize)
                    .ignoresSafeArea()

            case .denied:
                permissionMessage(
                    systemImage: "lock.camera",
                    text: "相机权限被拒绝。请在系统设置 ▸ Vela 中允许访问相机。"
                )

            case .unavailable:
                permissionMessage(
                    systemImage: "camera.on.rectangle",
                    text: "此设备不支持相机扫描。"
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

                Text("将二维码对准取景框")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 64)
            }
        }
        .onAppear {
            permission = Self.checkPermission()
            if permission == .notDetermined {
                Task { await awaitAuthorization() }
            }
        }
    }

    /// Re-checks until the system's first-run camera prompt is answered.
    /// Nothing else announces the answer to SwiftUI, and without this the
    /// scanner would sit unstarted after the user taps 允许.
    private func awaitAuthorization() async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { break }
        }
        permission = Self.checkPermission()
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

    private static func checkPermission() -> CameraPermission {
        // `isAvailable` is false until the camera is authorized, so it is
        // only consulted once authorization exists — otherwise a first run
        // would be told the device does not support scanning before the
        // system has even asked for permission.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return DataScannerViewController.isSupported && DataScannerViewController.isAvailable
                ? .granted
                : .unavailable
        @unknown default:
            return .unavailable
        }
    }
}
