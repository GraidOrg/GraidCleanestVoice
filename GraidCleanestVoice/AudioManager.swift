import AVFoundation
import Combine
import Foundation

// This class handles all the audio stuff - recording your voice and playing Gemini's voice
// Think of it like a microphone and speaker manager
class AudioManager: NSObject, ObservableObject {
    // Tells the UI whether we're currently recording
    @Published var isRecording = false
    
    // The main audio system that handles everything
    private let audioEngine = AVAudioEngine()
    // The speaker that plays Gemini's voice back to you
    private let audioPlayer = AVAudioPlayerNode()
    // The format we need to convert your voice to (Gemini wants 16kHz)
    private var targetFormat: AVAudioFormat?
    // The tool that converts your phone's audio format to Gemini's format
    private var audioConverter: AVAudioConverter?
    // Reference to Gemini service so we can send audio to it
    private var geminiService: GeminiLiveService?
    // Your phone's speaker format (varies by device, usually 48kHz)
    private var playbackFormat: AVAudioFormat?
    // The format Gemini sends audio in (24kHz)
    private let sourceFormat: AVAudioFormat
    
    override init() {
        // Gemini sends audio at 24,000 samples per second, mono (one channel), 16-bit
        // This is like knowing what language Gemini speaks
        sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        
        super.init()
        // Set up iOS audio system
        setupAudioSession()
        // Set up the speaker
        setupAudioPlayer()
    }
    
    // Sets up the speaker to play audio
    private func setupAudioPlayer() {
        // Add the speaker to the audio system
        audioEngine.attach(audioPlayer)
        // Ask your phone what format its speakers use (usually 48kHz)
        let destinationFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        playbackFormat = destinationFormat
        // Connect the speaker to the audio system
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: destinationFormat)
    }
    
    // Tells iOS we want to use both microphone and speaker
    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        // Enable recording AND playback, use speaker by default, allow Bluetooth
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        // Turn on the audio system
        try? audioSession.setActive(true)
    }
    
    // Starts listening to your microphone and sending audio to Gemini
    func startRecording(geminiService: GeminiLiveService) {
        self.geminiService = geminiService
        
        // Don't start if we're already recording
        guard !isRecording else { return }
        
        // Get the microphone
        let inputNode = audioEngine.inputNode
        // Ask what format your microphone uses (usually 48kHz)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Gemini wants audio at 16,000 samples per second (slower than your phone records)
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
        
        // Create a converter to change your phone's format to Gemini's format
        guard let targetFormat = targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return
        }
        audioConverter = converter
        
        // Install a "tap" on the microphone - like tapping a phone line
        // Every time we get audio, processAudioBuffer is called
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        // Get ready to start
        audioEngine.prepare()
        
        // Start the audio engine - microphone is now active!
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            return
        }
        
        // Listen for audio from Gemini (like tuning into a radio station)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReceivedAudio(_:)),
            name: .receivedAudioData,
            object: nil
        )
    }
    
    // Stops listening to microphone
    func stopRecording() {
        guard isRecording else { return }
        
        // Stop the audio engine
        audioEngine.stop()
        // Remove the tap from microphone
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        
        // Stop listening for Gemini's audio
        NotificationCenter.default.removeObserver(self)
    }
    
    // Called every time we get a chunk of audio from the microphone
    // Converts it to Gemini's format and sends it
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter,
              let targetFormat = targetFormat else {
            return
        }
        
        // Calculate how big the converted audio will be
        // If phone records at 48kHz and Gemini wants 16kHz, output is 1/3 the size
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = targetFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        // Create a buffer for the converted audio
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        // Convert from phone format to Gemini format (like translating languages)
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        // Make sure conversion worked
        guard error == nil,
              let channelData = convertedBuffer.int16ChannelData else {
            return
        }
        
        // Get the actual audio numbers (samples)
        let channelDataValue = channelData.pointee
        let frameLength = Int(convertedBuffer.frameLength)
        
        // Convert audio numbers into bytes (raw data)
        var audioData = Data()
        audioData.reserveCapacity(frameLength * 2)  // 2 bytes per sample
        
        // Convert each sample to bytes in little-endian format (Gemini's requirement)
        for i in 0..<frameLength {
            var littleEndian = channelDataValue[i].littleEndian
            audioData.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
        }
        
        // Send this audio chunk to Gemini
        geminiService?.sendAudioChunk(audioData)
    }
    
    // Called when Gemini sends us audio (via NotificationCenter)
    @objc private func handleReceivedAudio(_ notification: Notification) {
        guard let audioData = notification.object as? Data else { return }
        playAudioData(audioData)
    }
    
    // Plays audio that came from Gemini through your speakers
    private func playAudioData(_ audioData: Data) {
        guard let playbackFormat = playbackFormat else { return }
        
        // Calculate how many audio samples we have (2 bytes per sample)
        let frameCount = audioData.count / 2
        // Create a buffer in Gemini's format (24kHz)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        guard let channelData = sourceBuffer.int16ChannelData else {
            return
        }
        
        // Copy the audio bytes into the buffer
        audioData.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            channelData[0].update(from: samples.baseAddress!, count: frameCount)
        }
        
        // Convert from Gemini's format (24kHz) to your phone's format (usually 48kHz)
        guard let convertedBuffer = convert(sourceBuffer, to: playbackFormat) else {
            return
        }
        
        // Make sure audio engine is running
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        
        // Schedule this audio to play
        audioPlayer.scheduleBuffer(convertedBuffer) { }
        
        // Start playing if not already playing
        if !audioPlayer.isPlaying {
            audioPlayer.play()
        }
    }
    
    // Converts audio from one format to another (like converting video from 30fps to 60fps)
    // Used to convert Gemini's 24kHz audio to your phone's speaker format
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Create a converter tool
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            return nil
        }
        
        // Calculate output size based on sample rate difference
        // If converting 24kHz to 48kHz, output is 2x bigger
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        
        // Do the actual conversion
        var error: NSError?
        var hasProvidedBuffer = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedBuffer {
                // Already gave the buffer, signal we're done
                outStatus.pointee = .endOfStream
                return nil
            } else {
                // Give the buffer to convert
                hasProvidedBuffer = true
                outStatus.pointee = .haveData
                return buffer
            }
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        // Return converted buffer if conversion succeeded
        return error == nil ? convertedBuffer : nil
    }
}
