import SwiftUI

// The main screen you see - has a Start/Stop button
struct ContentView: View {
    // The service that talks to Gemini AI
    @StateObject private var geminiService = GeminiLiveService(apiKey: Config.geminiAPIKey)
    // The manager that handles microphone and speaker
    @StateObject private var audioManager = AudioManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Gemini Voice Agent")
                .font(.title)
                .padding()
            
            // The main button - Start begins conversation, Stop ends it
            Button(action: {
                if audioManager.isRecording {
                    stopConversation()
                } else {
                    startConversation()
                }
            }) {
                Text(audioManager.isRecording ? "Stop" : "Start")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 60)
                    .background(audioManager.isRecording ? Color.red : Color.blue)
                    .cornerRadius(12)
            }
            
            // Shows "Listening..." when recording
            if audioManager.isRecording {
                Text("Listening...")
                    .foregroundColor(.green)
                    .padding()
            }
        }
        .padding()
    }
    
    // Starts a conversation: connects to Gemini, then starts recording
    private func startConversation() {
        // Step 1: Connect to Gemini (like dialing a phone number)
        geminiService.connect()
        // Step 2: Wait half a second for connection to establish, then start recording
        // This gives Gemini time to say "I'm ready!" before we send audio
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            audioManager.startRecording(geminiService: geminiService)
        }
    }
    
    // Stops the conversation: stops recording, then disconnects
    private func stopConversation() {
        // Stop microphone first
        audioManager.stopRecording()
        // Then hang up the connection
        geminiService.disconnect()
    }
}

#Preview {
    ContentView()
}
