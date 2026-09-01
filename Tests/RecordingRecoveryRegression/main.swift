import Foundation

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("lectern-recording-recovery-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let ledger = RecordingFileLedger(recordingsDirectory: root)

let kept = root.appendingPathComponent("Lecture kept.wav")
let crashed = root.appendingPathComponent("Lecture crash.wav")
let deleted = root.appendingPathComponent("Lecture deleted.wav")
try Data("kept".utf8).write(to: kept)
try Data("crash".utf8).write(to: crashed)
try Data("deleted".utf8).write(to: deleted)

func names(_ candidates: [RecordingFileLedger.Candidate]) -> Set<String> {
    Set(candidates.map(\.url.lastPathComponent))
}

let beforeDelete = ledger.recoverCandidates(claimedPaths: [kept.path])
guard names(beforeDelete) == ["Lecture crash.wav", "Lecture deleted.wav"] else {
    fputs("FAIL: crash leftovers should be recovered, claimed files should not\n", stderr)
    exit(1)
}

ledger.discard(filePath: deleted.path)

guard !FileManager.default.fileExists(atPath: deleted.path) else {
    fputs("FAIL: deleting a lecture should remove its recording file\n", stderr)
    exit(1)
}

try Data("deleted-again".utf8).write(to: deleted)

let afterDelete = ledger.recoverCandidates(claimedPaths: [kept.path])
guard names(afterDelete) == ["Lecture crash.wav"] else {
    fputs("FAIL: a deleted lecture's WAV came back as a recovery candidate\n", stderr)
    exit(1)
}

print("PASS: deleted lecture recordings stay discarded across recovery")
