import SwiftUI

struct ContentView: View {
    @StateObject private var geminiService = GeminiLiveService(apiKey: Config.geminiAPIKey)
    @StateObject private var audioManager = AudioManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Gemini Voice Agent")
                .font(.title)
                .padding()
            
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
            
            if audioManager.isRecording {
                Text("Listening...")
                    .foregroundColor(.green)
                    .padding()
            }
        }
        .padding()
    }
    
    private func startConversation() {
        geminiService.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            audioManager.startRecording(geminiService: geminiService)
        }
    }
    
    private func stopConversation() {
        audioManager.stopRecording()
        geminiService.disconnect()
    }
}

#Preview {
    ContentView()
}
