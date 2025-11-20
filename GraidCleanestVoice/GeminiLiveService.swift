import Combine
import Foundation

// This class handles talking to Google's Gemini AI over the internet
// Think of it like a phone call - it connects, sends your voice, and receives AI's voice back
class GeminiLiveService: NSObject, ObservableObject {
    // This tells the UI whether we're connected to Gemini or not
    @Published var isConnected = false
    
    // The connection to Gemini's servers (like a phone line)
    private var webSocketTask: URLSessionWebSocketTask?
    // The manager that handles the connection
    private var urlSession: URLSession?
    // Your secret password to use Gemini API
    private let apiKey: String
    // Has Gemini finished setting up? We can't send audio until this is true
    private var setupCompleted = false
    // Are we in the process of hanging up? Used to stop listening for messages
    private var isDisconnecting = false
    
    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }
    
    // Starts the connection to Gemini - like dialing a phone number
    func connect() {
        // Don't connect if we're already connected
        guard !isConnected else { return }
        
        isDisconnecting = false
        
        // This is Gemini's address on the internet, with your API key attached
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        
        guard let url = URL(string: urlString) else { return }
        
        // Configure how we connect - wait for internet connection before giving up
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        
        // Create a queue to handle messages one at a time (like a single phone line)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        
        // Create the connection manager
        urlSession = URLSession(configuration: configuration,
                               delegate: self,
                               delegateQueue: delegateQueue)
        
        // Start the actual connection using Google's special protocol
        webSocketTask = urlSession?.webSocketTask(with: url, protocols: ["googleapis.bidi"])
        webSocketTask?.resume()
        
        setupCompleted = false
    }
    
    // Sends the first message to Gemini telling it how to behave
    // Like saying "Hello, I want to talk using voice only"
    private func sendSetupMessage() {
        // Tell Gemini: use this specific model and only respond with audio (no text)
        let setupConfig: [String: Any] = [
            "setup": [
                "model": "models/gemini-2.5-flash-native-audio-preview-09-2025",
                "system_instruction": [
                    "parts": [["text": """
                    You will tutor students in math. 
                    You will start each session by initiating the conversation and introducing yourself as 
                    "Hi, I'm an AI tutor! What math problem can I help you with?" and then look for the problem on the screen,
                    and read the text of the problem aloud to the student. 
                    If you do not see a math problem, ask the student to read it for you to identify.
                    Be sure to repeat the problem back to the student to confirm you have it correct.
                    You will tutor by doing two things: 
                    (1) processing what the student is writing each step of the way, and 
                    (2) tutoring the student in a way that leads students to the answer 
                    and does not give away the answer.
                    For the first step, you will continuously process the student's writing and be sure
                    to recognize the mathematical notation and the steps the student is taking.
                    For the second step, you will tutor the student in a way that leads students to the answer
                    and does not give away the answer.
                    There will be 3 phases of your tutoring: the foresight phase, the tutoring phase, and
                    the reflection phase.
                    For the foresight phase, you will ask the student if they know how to solve the problem.
                    If they know, then ask them to explain how they would solve the problem. If you notice any mistakes, 
                    be sure to congratualte them on what they got right and politely correct them.
                    If they do not know, then ask them what they do know, and help them understand the basic steps to 
                    solve the problem. They do not need to understand this completely, but if the student makes some 
                    progress then you can continue to the tutoring phase.
                    In the tutoring phase, you will tutor the student in a way that leads students to the answer
                    and does not give away the answer. You will use the following steps to tutor the student:
                    (1) Ask the student to attempt to solve the problem.
                    (2) Do not talk until the student asks a question.
                    (3) Ask a question to help the student think about the correct way to proceed.
                    Be sure to use casual language and use metaphors when necessary. 
                    (4) If you notice that the student is really stuck then you may tell them the answer for that 
                    step and ask the student to continue to the next step.
                    You want to keep the student engaged in a state of flow, where the problem is neither too 
                    easy nor too difficult.
                    In the reflection phase, you will ask the student to reflect on the problem and the steps they took to solve it
                    so they can apply the same concepts to future problems.
                    Ask them what they learned from the problem and how they can make sure to approach the problem better next time.
                    Ask them if they have any questions about the problem or the steps they took to solve it.
                    """]]
                ],
                "generation_config": [
                    "response_modalities": ["AUDIO"]  // Only send audio, not text
                ]
            ]
        ]
        
        // Convert our settings into a format Gemini understands (JSON)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: setupConfig) else { return }
        
        // Send the setup message over the connection
        let message = URLSessionWebSocketTask.Message.data(jsonData)
        webSocketTask?.send(message) { _ in }
    }
    
    // Sends a piece of your voice recording to Gemini
    // Called many times per second as you speak (like sending video frames)
    func sendAudioChunk(_ audioData: Data) {
        // Don't send anything until Gemini says it's ready
        guard setupCompleted else { return }
        
        // Wrap the audio in the format Gemini expects
        // Gemini needs audio encoded as text (base64) because it travels over the internet
        let audioMessage: [String: Any] = [
            "realtime_input": [
                "media_chunks": [
                    [
                        "data": audioData.base64EncodedString(),  // Convert audio to text format
                        "mime_type": "audio/pcm;rate=16000"  // Tell Gemini: this is audio at 16,000 samples per second
                    ]
                ]
            ]
        ]
        
        // Convert to JSON format and send
        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioMessage) else { return }
        
        let message = URLSessionWebSocketTask.Message.data(jsonData)
        webSocketTask?.send(message) { _ in }
    }
    
    // Keeps listening for messages from Gemini (like keeping the phone line open)
    // Calls itself again after each message to keep listening forever
    private func listenForMessages() {
        // Stop if we don't have a connection or we're disconnecting
        guard let webSocketTask = webSocketTask, !isDisconnecting else { return }
        
        // Wait for the next message from Gemini
        webSocketTask.receive { [weak self] result in
            guard let self = self, !self.isDisconnecting else { return }
            
            switch result {
            case .success(let message):
                // Got a message! Process it and keep listening
                self.handle(message)
                self.listenForMessages()  // Listen again for the next message
            case .failure:
                // Connection broke, update the UI
                DispatchQueue.main.async {
                    self.isConnected = false
                }
            }
        }
    }
    
    // Handles incoming messages from Gemini
    // Messages can come as binary data or text - we handle both
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Message came as binary data (most common)
            processResponseData(data)
        case .string(let text):
            // Message came as text - convert to data first
            guard let data = text.data(using: .utf8) else { return }
            processResponseData(data)
        @unknown default:
            break
        }
    }
    
    // Looks at what Gemini sent us and figures out what to do with it
    private func processResponseData(_ data: Data) {
        // Convert the message from JSON format into something we can read
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // Check if Gemini is saying "I'm ready!" (setup complete)
        if json["setupComplete"] != nil {
            setupCompleted = true  // Now we can start sending audio!
            return
        }
        
        // Check if Gemini sent us audio (its voice response)
        // The structure is: serverContent -> modelTurn -> parts -> audio data
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            
            // Look through all the parts to find audio
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.starts(with: "audio/"),  // Make sure it's audio, not text
                   let audioDataBase64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: audioDataBase64) {
                    // Found audio! Send it to AudioManager to play through speakers
                    NotificationCenter.default.post(name: .receivedAudioData, object: audioData)
                }
            }
        }
    }
    
    // Hangs up the connection to Gemini
    func disconnect() {
        isDisconnecting = true  // Tell the listening loop to stop
        // Close the connection politely
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        // Cancel all pending network requests
        urlSession?.invalidateAndCancel()
        // Clean up
        webSocketTask = nil
        urlSession = nil
        setupCompleted = false
        // Update UI to show we're disconnected
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}

// These functions are called automatically by iOS when the connection changes
extension GeminiLiveService: URLSessionWebSocketDelegate {
    // Called when connection is successfully established (like when someone picks up the phone)
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            // Now that we're connected, send the setup message
            self?.sendSetupMessage()
            // Start listening for Gemini's responses
            self?.listenForMessages()
        }
    }
    
    // Called when connection closes (like hanging up)
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    // Called when connection ends (with or without an error)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}

// This is like a radio station name - AudioManager listens to this "station"
// When we post here, AudioManager hears it and plays the audio
extension Notification.Name {
    static let receivedAudioData = Notification.Name("receivedAudioData")
}
