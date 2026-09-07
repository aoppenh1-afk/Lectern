import AVFoundation
import XCTest

final class CaptureSourceTests: XCTestCase {
    func testSystemAudioSourceDoesNotRequireMicrophone() {
        XCTAssertTrue(CaptureSource.microphone.includesMicrophone)
        XCTAssertFalse(CaptureSource.microphone.includesSystemAudio)
        XCTAssertFalse(CaptureSource.systemAudio.includesMicrophone)
        XCTAssertTrue(CaptureSource.systemAudio.includesSystemAudio)
        XCTAssertFalse(CaptureSource.zoomApp.includesMicrophone)
        XCTAssertTrue(CaptureSource.zoomApp.includesSystemAudio)
        XCTAssertTrue(CaptureSource.zoomApp.zoomAppOnly)
        XCTAssertFalse(CaptureSource.systemAudio.zoomAppOnly)
        XCTAssertFalse(CaptureSource.mixed.zoomAppOnly)
        XCTAssertTrue(CaptureSource.mixed.includesMicrophone)
        XCTAssertTrue(CaptureSource.mixed.includesSystemAudio)
    }

    func testZoomRecordButtonTitle() {
        XCTAssertEqual(CaptureSource.systemAudio.recordButtonTitle, "Record Zoom")
        XCTAssertEqual(CaptureSource.zoomApp.recordButtonTitle, "Record Zoom app")
        XCTAssertEqual(CaptureSource.mixed.recordButtonTitle, "Record Zoom + Mic")
    }

    func testPreferredSourceRoundTrip() {
        let key = CaptureSource.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        CaptureSource.persist(.systemAudio)
        XCTAssertEqual(CaptureSource.preferred, .systemAudio)
        CaptureSource.persist(.zoomApp)
        XCTAssertEqual(CaptureSource.preferred, .zoomApp)
        CaptureSource.persist(.mixed)
        XCTAssertEqual(CaptureSource.preferred, .mixed)
        CaptureSource.persist(.microphone)
        XCTAssertEqual(CaptureSource.preferred, .microphone)
    }

    func testZoomBundleIdentification() {
        XCTAssertTrue(MeetingAudioTarget.isZoomBundleID("us.zoom.xos"))
        XCTAssertTrue(MeetingAudioTarget.isZoomBundleID("us.zoom.CptHost"))
        XCTAssertTrue(MeetingAudioTarget.isZoomBundleID("us.zoom.aomhost"))
        XCTAssertTrue(MeetingAudioTarget.isZoomBundleID("us.zoom.caphost"))
        XCTAssertTrue(MeetingAudioTarget.isZoomBundleID("us.zoom.ringcentral"))
        XCTAssertFalse(MeetingAudioTarget.isZoomBundleID("com.apple.Safari"))
        XCTAssertFalse(MeetingAudioTarget.isZoomBundleID(nil))
        XCTAssertFalse(MeetingAudioTarget.isZoomBundleID(""))
    }
}

final class WAVMixdownTests: XCTestCase {
    func testSaturatingAddClamps() {
        XCTAssertEqual(WAVMixdown.saturatingAdd(20_000, 20_000), Int16.max)
        XCTAssertEqual(WAVMixdown.saturatingAdd(-20_000, -20_000), Int16.min)
        XCTAssertEqual(WAVMixdown.saturatingAdd(1_000, 2_000), 3_000)
    }

    func testMixSumsAndPadsShorterFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mic = try writeWAV(samples: [1_000, 2_000, 3_000], in: directory, name: "mic.wav")
        let system = try writeWAV(samples: [500, 400], in: directory, name: "system.wav")
        let destination = directory.appendingPathComponent("mixed.wav")

        let size = try WAVMixdown.mix(urls: [system, mic], destination: destination)
        XCTAssertGreaterThan(size, 44)

        let reader = try WAVMixdown.Reader(url: destination)
        defer { reader.close() }
        XCTAssertEqual(reader.sampleRate, 16_000)
        XCTAssertEqual(try reader.readFrames(8), [1_500, 2_400, 3_000])
    }

    func testPCMBufferCloneIsIndependent() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        buffer.floatChannelData![0][0] = 0.5

        let copy = try XCTUnwrap(buffer.cloned())
        buffer.floatChannelData![0][0] = 0
        XCTAssertEqual(copy.floatChannelData![0][0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(copy.frameLength, 4)
    }

    private func writeWAV(samples: [Int16], in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        writer.append(int16Samples: samples[...])
        _ = try writer.finish()
        return url
    }
}

final class CaptureRecoveryTests: XCTestCase {
    func testMixedSidecarsCollapseToSystemTrack() {
        let stamp = "Lecture 2026-09-07 12.00.00"
        let system = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/\(stamp)-system.wav"),
            capturedAt: Date(timeIntervalSince1970: 10),
            sizeBytes: 80
        )
        let mic = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/\(stamp)-mic.wav"),
            capturedAt: Date(timeIntervalSince1970: 10),
            sizeBytes: 40
        )

        let adopted = RecordingFileLedger.collapseRecoveryCandidates([mic, system])
        XCTAssertEqual(adopted.map(\.url.lastPathComponent), ["\(stamp)-system.wav"])
    }

    func testFinishedMixIsPreferredOverSidecars() {
        let stamp = "Lecture 2026-09-07 12.00.00"
        let mixed = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/\(stamp).wav"),
            capturedAt: Date(timeIntervalSince1970: 20),
            sizeBytes: 100
        )
        let system = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/\(stamp)-system.wav"),
            capturedAt: Date(timeIntervalSince1970: 20),
            sizeBytes: 80
        )

        let adopted = RecordingFileLedger.collapseRecoveryCandidates([system, mixed])
        XCTAssertEqual(adopted.map(\.url.lastPathComponent), ["\(stamp).wav"])
    }

    func testUnrelatedRecordingsStaySeparate() {
        let first = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/Lecture A.wav"),
            capturedAt: Date(timeIntervalSince1970: 1),
            sizeBytes: 10
        )
        let second = RecordingFileLedger.Candidate(
            url: URL(fileURLWithPath: "/tmp/Lecture B.wav"),
            capturedAt: Date(timeIntervalSince1970: 2),
            sizeBytes: 10
        )

        let adopted = RecordingFileLedger.collapseRecoveryCandidates([second, first])
        XCTAssertEqual(adopted.map(\.url.lastPathComponent), ["Lecture A.wav", "Lecture B.wav"])
    }
}
