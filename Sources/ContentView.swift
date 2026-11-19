import SwiftUI
import UIKit
import Network

// ------------------------------------------------------------------------
// UDP Sender to Blender Add-on (Port 9876)
// ------------------------------------------------------------------------
class BlenderUDPClient: ObservableObject {
    @Published var laptopIP: String = UserDefaults.standard.string(forKey: "laptopIP") ?? "192.168.1.100"
    @Published var lastAction: String = "Ready — Hover or Double-Tap Pencil Pro"
    @Published var currentRollDegrees: Double = 0.0

    private var connection: NWConnection?

    func updateIP(_ newIP: String) {
        laptopIP = newIP
        UserDefaults.standard.set(newIP, forKey: "laptopIP")
        setupConnection()
    }

    func setupConnection() {
        connection?.cancel()
        let host = NWEndpoint.Host(laptopIP)
        let port = NWEndpoint.Port(integerLiteral: 9876)
        connection = NWConnection(host: host, port: port, using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))
    }

    func sendEvent(_ eventName: String, extra: [String: Any] = [:]) {
        if connection == nil { setupConnection() }
        var payload: [String: Any] = ["event": eventName]
        for (k, v) in extra { payload[k] = v }

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })

        DispatchQueue.main.async {
            self.lastAction = "Sent: \(eventName)"
        }
    }
}

// ------------------------------------------------------------------------
// Apple Pencil Pro Sensor Pad (Double-Tap, Squeeze & Barrel Roll)
// ------------------------------------------------------------------------
struct PencilSensorRepresentable: UIViewRepresentable {
    @ObservedObject var client: BlenderUDPClient

    func makeUIView(context: Context) -> PencilSensorUIView {
        let view = PencilSensorUIView()
        view.client = client
        return view
    }

    func updateUIView(_ uiView: PencilSensorUIView, context: Context) {
        uiView.client = client
    }
}

class PencilSensorUIView: UIView, UIPencilInteractionDelegate {
    var client: BlenderUDPClient?
    private var lastTriggerRollAngle: CGFloat?
    private var lastMenuTriggerTime: Date = .distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.35)
        layer.cornerRadius = 20
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor

        // 1. Apple Pencil Double-Tap & Squeeze Interaction
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        // 2. Apple Pencil Pro Barrel Roll Hover Gesture
        let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hoverGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(hoverGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Apple Pencil Double-Tap Handler -> Context-Aware Flip (Add <-> Subtract)
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        client?.sendEvent("double_tap")
    }

    // Apple Pencil Pro Squeeze Handler (iOS 17.5+)
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended {
            client?.sendEvent("squeeze")
        }
    }

    // Apple Pencil Pro Barrel Roll Handler -> Opens Quick Menu when rotated > 35 degrees
    @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
        if #available(iOS 17.5, *) {
            let rollRadians = gesture.rollAngle
            let rollDegrees = Double(rollRadians) * 180.0 / .pi

            DispatchQueue.main.async {
                self.client?.currentRollDegrees = rollDegrees
            }

            if gesture.state == .began {
                lastTriggerRollAngle = rollRadians
            } else if gesture.state == .changed {
                if let startAngle = lastTriggerRollAngle {
                    let delta = abs(rollRadians - startAngle)
                    // Trigger Quick Menu when barrel is rolled ~35 degrees (0.61 rad)
                    if delta > 0.61 && Date().timeIntervalSince(lastMenuTriggerTime) > 0.8 {
                        lastMenuTriggerTime = Date()
                        lastTriggerRollAngle = rollRadians
                        client?.sendEvent("barrel_roll_menu", extra: ["roll": rollDegrees])
                    }
                } else {
                    lastTriggerRollAngle = rollRadians
                }
            } else if gesture.state == .ended || gesture.state == .cancelled {
                lastTriggerRollAngle = nil
            }
        }
    }
}

// ------------------------------------------------------------------------
// Main Slide-Over / Split-View Companion Interface
// ------------------------------------------------------------------------
struct ContentView: View {
    @StateObject private var client = BlenderUDPClient()
    @State private var ipInput: String = UserDefaults.standard.string(forKey: "laptopIP") ?? "192.168.1.100"

    var body: some View {
        VStack(spacing: 16) {
            Text("PencilFlow Pro")
                .font(.headline)
                .padding(.top, 8)

            // Laptop IP Input (Shown inside Blender's PencilFlow sidebar)
            HStack {
                TextField("Laptop IP (e.g. 192.168.1.5)", text: $ipInput)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                Button("Connect") {
                    client.updateIP(ipInput)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            // Live Sensor Pad for Apple Pencil Pro
            ZStack {
                PencilSensorRepresentable(client: client)

                VStack(spacing: 10) {
                    Image(systemName: "applepencil.gen2")
                        .font(.system(size: 36))
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(client.currentRollDegrees))

                    Text("Pencil Pro Sensor Zone")
                        .font(.subheadline.bold())

                    Text("• Double-Tap: Flip Add (+) ↔ Subtract (-)\n• Barrel Roll: Open Custom Quick Menu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(format: "Barrel Roll: %.0f°", client.currentRollDegrees))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                }
                .padding()
                .allowsHitTesting(false)
            }
            .padding(.horizontal)

            // Manual Backup Buttons
            HStack(spacing: 12) {
                Button {
                    client.sendEvent("double_tap")
                } label: {
                    Label("Flip +/-", systemImage: "plusminus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    client.sendEvent("barrel_roll_menu")
                } label: {
                    Label("Quick Menu", systemImage: "circle.grid.cross")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Text(client.lastAction)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .onAppear {
            client.setupConnection()
        }
    }
}
