import CoreMedia
import Foundation
@preconcurrency import AVFAudio

extension AVAudioPCMBuffer {
    /// Deep copy so the buffer can outlive an audio-render or SCStream callback.
    func cloned() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0 else { return copy }

        if format.isInterleaved {
            let byteCount = Int(audioBufferList.pointee.mBuffers.mDataByteSize)
            if let src = audioBufferList.pointee.mBuffers.mData,
               let dst = copy.mutableAudioBufferList.pointee.mBuffers.mData,
               byteCount > 0 {
                memcpy(dst, src, byteCount)
            }
            return copy
        }

        if let src = floatChannelData, let dst = copy.floatChannelData {
            let byteCount = frames * MemoryLayout<Float>.size
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], byteCount)
            }
            return copy
        }

        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            let byteCount = frames * MemoryLayout<Int16>.size
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], byteCount)
            }
            return copy
        }

        return copy
    }

    /// Builds a PCM buffer from an SCStream audio sample, copying out of the
    /// CMSampleBuffer so non-interleaved Float32 stereo (macOS 26's layout)
    /// is preserved.
    static func fromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}
