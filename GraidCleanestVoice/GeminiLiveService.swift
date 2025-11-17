import Combine
import Foundation

class GeminiLiveService: NSObject, ObservableObject {
    @Published var isConnected = false
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let apiKey: String
    private var setupCompleted = false
    private var isDisconnecting = false
    
    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }
    
    func connect() {
        guard !isConnected else { return }
        
        isDisconnecting = false
        
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        
        guard let url = URL(string: urlString) else { return }
        
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        
        urlSession = URLSession(configuration: configuration,
                               delegate: self,
                               delegateQueue: delegateQueue)
        
        webSocketTask = urlSession?.webSocketTask(with: url, protocols: ["googleapis.bidi"])
        webSocketTask?.resume()
        
        setupCompleted = false
    }
    
    private func sendSetupMessage() {
        let setupConfig: [String: Any] = [
            "setup": [
                "model": "models/gemini-2.5-flash-native-audio-preview-09-2025",
                "generation_config": [
                    "response_modalities": ["AUDIO"]
                ]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: setupConfig) else { return }
        
        let message = URLSessionWebSocketTask.Message.data(jsonData)
        webSocketTask?.send(message) { _ in }
    }
    
    func sendAudioChunk(_ audioData: Data) {
        guard setupCompleted else { return }
        
        let audioMessage: [String: Any] = [
            "realtime_input": [
                "media_chunks": [
                    [
                        "data": audioData.base64EncodedString(),
                        "mime_type": "audio/pcm;rate=16000"
                    ]
                ]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioMessage) else { return }
        
        let message = URLSessionWebSocketTask.Message.data(jsonData)
        webSocketTask?.send(message) { _ in }
    }
    
    private func listenForMessages() {
        guard let webSocketTask = webSocketTask, !isDisconnecting else { return }
        
        webSocketTask.receive { [weak self] result in
            guard let self = self, !self.isDisconnecting else { return }
            
            switch result {
            case .success(let message):
                self.handle(message)
                self.listenForMessages()
            case .failure:
                DispatchQueue.main.async {
                    self.isConnected = false
                }
            }
        }
    }
    
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            processResponseData(data)
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            processResponseData(data)
        @unknown default:
            break
        }
    }
    
    private func processResponseData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        if json["setupComplete"] != nil {
            setupCompleted = true
            return
        }
        
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.starts(with: "audio/"),
                   let audioDataBase64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: audioDataBase64) {
                    NotificationCenter.default.post(name: .receivedAudioData, object: audioData)
                }
            }
        }
    }
    
    func disconnect() {
        isDisconnecting = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocketTask = nil
        urlSession = nil
        setupCompleted = false
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.sendSetupMessage()
            self?.listenForMessages()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}

extension Notification.Name {
    static let receivedAudioData = Notification.Name("receivedAudioData")
}
