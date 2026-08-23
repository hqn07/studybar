import SwiftUI
import AVFoundation

enum BarcodeScanner {
    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

/// Live camera view that reads EAN-13/EAN-8 book barcodes and returns the ISBN.
struct BarcodeScannerView: NSViewRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeNSView(context: Context) -> ScannerNSView {
        let view = ScannerNSView()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            DispatchQueue.main.async { view.start(delegate: context.coordinator) }
        }
        return view
    }
    func updateNSView(_ nsView: ScannerNSView, context: Context) {}
    static func dismantleNSView(_ nsView: ScannerNSView, coordinator: Coordinator) { nsView.stop() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        private var handled = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            handled = true
            onScan(value)
        }
    }
}

final class ScannerNSView: NSView {
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    func start(delegate: AVCaptureMetadataOutputObjectsDelegate) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.ean13, .ean8]
        }
        let pv = AVCaptureVideoPreviewLayer(session: session)
        pv.videoGravity = .resizeAspectFill
        pv.frame = bounds
        layer?.addSublayer(pv)
        preview = pv
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func layout() {
        super.layout()
        preview?.frame = bounds
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }
}
