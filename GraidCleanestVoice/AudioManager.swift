import AVFoundation
import Combine
import Foundation

class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false
    
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private var targetFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var geminiService: GeminiLiveService?
    private var playbackFormat: AVAudioFormat?
    private let sourceFormat: AVAudioFormat
    
    override init() {
        sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        
        super.init()
        setupAudioSession()
        setupAudioPlayer()
    }
    
    private func setupAudioPlayer() {
        audioEngine.attach(audioPlayer)
        let destinationFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        playbackFormat = destinationFormat
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: destinationFormat)
    }
    
    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)
    }
    
    func startRecording(geminiService: GeminiLiveService) {
        self.geminiService = geminiService
        
        guard !isRecording else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
        
        guard let targetFormat = targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return
        }
        audioConverter = converter
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            return
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReceivedAudio(_:)),
            name: .receivedAudioData,
            object: nil
        )
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        
        NotificationCenter.default.removeObserver(self)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter,
              let targetFormat = targetFormat else {
            return
        }
        
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = targetFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        guard error == nil,
              let channelData = convertedBuffer.int16ChannelData else {
            return
        }
        
        let channelDataValue = channelData.pointee
        let frameLength = Int(convertedBuffer.frameLength)
        
        var audioData = Data()
        audioData.reserveCapacity(frameLength * 2)
        
        for i in 0..<frameLength {
            var littleEndian = channelDataValue[i].littleEndian
            audioData.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
        }
        
        geminiService?.sendAudioChunk(audioData)
    }
    
    @objc private func handleReceivedAudio(_ notification: Notification) {
        guard let audioData = notification.object as? Data else { return }
        playAudioData(audioData)
    }
    
    private func playAudioData(_ audioData: Data) {
        guard let playbackFormat = playbackFormat else { return }
        
        let frameCount = audioData.count / 2
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        guard let channelData = sourceBuffer.int16ChannelData else {
            return
        }
        
        audioData.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            channelData[0].update(from: samples.baseAddress!, count: frameCount)
        }
        
        guard let convertedBuffer = convert(sourceBuffer, to: playbackFormat) else {
            return
        }
        
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        
        audioPlayer.scheduleBuffer(convertedBuffer) { }
        
        if !audioPlayer.isPlaying {
            audioPlayer.play()
        }
    }
    
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            return nil
        }
        
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        
        var error: NSError?
        var hasProvidedBuffer = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedBuffer {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                hasProvidedBuffer = true
                outStatus.pointee = .haveData
                return buffer
            }
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        return error == nil ? convertedBuffer : nil
    }
}
