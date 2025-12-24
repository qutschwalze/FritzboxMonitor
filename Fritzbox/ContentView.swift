import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement // Wichtig für Autostart

// --- TRAFFIC MANAGER (Singleton) ---
class TrafficManager: ObservableObject {
    static let shared = TrafficManager()
    
    // IP-Adresse
    @Published var fritzIP: String {
        didSet { UserDefaults.standard.set(fritzIP, forKey: "FRITZ_IP") }
    }
    
    // Autostart Status
    @Published var launchAtLogin: Bool {
        didSet {
            // Registriert oder deregistriert die App als Login Item
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
    
    // Status & Daten
    @Published var connectionStatus: String = "Suche..."
    @Published var downText: String = "..."
    @Published var upText: String = "..."
    
    // Historie
    @Published var historyDown: [Double] = Array(repeating: 0.0, count: 40)
    @Published var historyUp: [Double] = Array(repeating: 0.0, count: 40)
    
    private var timer: Timer?
    let PORT = "49000"
    let MAX_DOWN = 100.0
    let MAX_UP = 40.0
    
    init() {
        // Lade IP
        self.fritzIP = UserDefaults.standard.string(forKey: "FRITZ_IP") ?? "192.168.178.1"
        
        // Prüfe Autostart-Status beim Start
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        
        // Startet Suche
        discoverFritzBox()
    }
    
    func discoverFritzBox() {
        connectionStatus = "Prüfe \(fritzIP)..."
        checkConnection(ip: fritzIP) { success in
            DispatchQueue.main.async {
                if success {
                    self.connectionStatus = "Verbinde..."
                    self.startMonitoring()
                } else {
                    self.checkConnection(ip: "fritz.box") { success2 in
                        DispatchQueue.main.async {
                            if success2 {
                                self.fritzIP = "fritz.box"
                                self.connectionStatus = "Verbinde..."
                                self.startMonitoring()
                            } else {
                                self.connectionStatus = "Nicht gefunden"
                            }
                        }
                    }
                }
            }
        }
    }
    
    func retryConnection() {
        timer?.invalidate()
        discoverFritzBox()
    }
    
    private func checkConnection(ip: String, completion: @escaping (Bool) -> Void) {
        let host = NWEndpoint.Host(ip)
        let port = NWEndpoint.Port(rawValue: 49000)!
        let connection = NWConnection(host: host, port: port, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.cancel()
                completion(true)
            case .failed(_), .cancelled:
                completion(false)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if connection.state != .ready { connection.cancel() }
        }
    }
    
    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in self.fetchTraffic() }
        fetchTraffic()
    }
    
    func fetchTraffic() {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:GetAddonInfos xmlns:u="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1" /></s:Body>
        </s:Envelope>
        """
        
        guard let url = URL(string: "http://\(fritzIP):\(PORT)/igdupnp/control/WANCommonIFC1") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1#GetAddonInfos", forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapBody.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil, let responseStr = String(data: data, encoding: .utf8) else { return }
            
            if let downStr = self.extractValue(from: responseStr, tag: "NewByteReceiveRate"),
               let upStr = self.extractValue(from: responseStr, tag: "NewByteSendRate"),
               let downBytes = Double(downStr),
               let upBytes = Double(upStr) {
                
                let downMbit = (downBytes * 8) / 1_000_000
                let upMbit = (upBytes * 8) / 1_000_000
                
                DispatchQueue.main.async {
                    if !self.connectionStatus.contains("Verbunden") {
                        self.connectionStatus = "Verbunden"
                    }
                    self.downText = self.formatBytes(bytes: downBytes)
                    self.upText = self.formatBytes(bytes: upBytes)
                    
                    self.historyDown.append(downMbit)
                    if self.historyDown.count > 40 { self.historyDown.removeFirst() }
                    
                    self.historyUp.append(upMbit)
                    if self.historyUp.count > 40 { self.historyUp.removeFirst() }
                }
            }
        }.resume()
    }
    
    private func formatBytes(bytes: Double) -> String {
        let kb = bytes / 1024
        if kb > 999 { return String(format: "%.1f MB/s", kb / 1024) }
        else { return String(format: "%.0f KB/s", kb) }
    }
    
    private func extractValue(from text: String, tag: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = text as NSString
        let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        return results.first.map { nsString.substring(with: $0.range(at: 1)) }
    }
    
    func openFritzBoxInterface() {
        if let url = URL(string: "http://\(fritzIP)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// --- APP DELEGATE ---
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 100)
        
        if let button = statusItem?.button {
            let hostingView = NSHostingView(rootView: MenuBarView())
            hostingView.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
            button.addSubview(hostingView)
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover.contentViewController = NSHostingController(rootView: ContentView())
        popover.behavior = .transient
    }
    
    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover.isShown { popover.performClose(nil) }
            else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        }
    }
}

// --- VISUALISIERUNG (Graph) ---
struct SplitGraph: View {
    var downData: [Double]
    var upData: [Double]
    @ObservedObject var manager = TrafficManager.shared
    
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            let midY = h / 2
            
            Path { p in // UP (Rot)
                let step = w / CGFloat(upData.count - 1)
                p.move(to: CGPoint(x: 0, y: midY))
                for (i, v) in upData.enumerated() {
                    let bar = CGFloat(min(v, manager.MAX_UP) / manager.MAX_UP) * midY
                    p.addLine(to: CGPoint(x: CGFloat(i) * step, y: midY - bar))
                }
                p.addLine(to: CGPoint(x: w, y: midY))
                p.closeSubpath()
            }.fill(Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.8))
            
            Path { p in // DOWN (Blau)
                let step = w / CGFloat(downData.count - 1)
                p.move(to: CGPoint(x: 0, y: midY))
                for (i, v) in downData.enumerated() {
                    let bar = CGFloat(min(v, manager.MAX_DOWN) / manager.MAX_DOWN) * midY
                    p.addLine(to: CGPoint(x: CGFloat(i) * step, y: midY + bar))
                }
                p.addLine(to: CGPoint(x: w, y: midY))
                p.closeSubpath()
            }.fill(Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.8))
            
            Path { p in
                p.move(to: CGPoint(x: 0, y: midY))
                p.addLine(to: CGPoint(x: w, y: midY))
            }.stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        }
    }
}

// --- MENÜLEISTE ---
struct MenuBarView: View {
    @ObservedObject var manager = TrafficManager.shared
    var body: some View {
        HStack(spacing: 6) {
            SplitGraph(downData: manager.historyDown, upData: manager.historyUp)
                .frame(width: 50, height: 18)
            VStack(alignment: .trailing, spacing: -1) {
                Text(manager.upText).foregroundColor(Color.white.opacity(0.8))
                Text(manager.downText).fontWeight(.bold).foregroundColor(.white)
            }
            .font(.system(size: 9, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .frame(width: 100, height: 22)
    }
}

// --- POPOVER MENÜ ---
struct ContentView: View {
    @ObservedObject var manager = TrafficManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FRITZ!Box Monitor").font(.headline)
            Divider()
            
            // Status
            HStack {
                Text("Status:")
                Spacer()
                if manager.connectionStatus == "Verbunden" {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Verbunden").foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(manager.connectionStatus).foregroundColor(.orange).font(.caption)
                }
            }
            .font(.subheadline)
            
            // IP Eingabe (nur wenn nötig)
            VStack(alignment: .leading, spacing: 4) {
                Text("IP-Adresse:").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("IP", text: $manager.fritzIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Verbinden") { manager.retryConnection() }
                }
            }
            
            Button("FRITZ!Box öffnen") { manager.openFritzBoxInterface() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            
            Divider()
            
            // Autostart Option
            Toggle("Start bei Login", isOn: $manager.launchAtLogin)
                .font(.caption)
            
            Divider()
            
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(width: 220)
    }
}

@main
struct FBTrafficMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
