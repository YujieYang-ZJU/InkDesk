import Foundation
import CryptoKit

struct SyncPageSummary: Codable, Equatable {
    var id: UUID
    var name: String
}

struct SyncFrameMetadata: Codable, Equatable {
    var pages: [SyncPageSummary]
    var focusedTaskID: UUID?
    var pollSeconds: Int
}

struct QueuedSyncFrame: Codable {
    var frame: FramePayload
    var metadata: SyncFrameMetadata

    func representsSameContent(as other: QueuedSyncFrame) -> Bool {
        frame.pageID == other.frame.pageID && frame.hash == other.frame.hash &&
        frame.taskIDs == other.frame.taskIDs && metadata == other.metadata
    }

    func manifest(frameURL: String, transferID: UUID? = nil) -> [String: Any] {
        var result: [String: Any] = ["version": 1, "width": 800, "height": 480, "pixelFormat": "mono1-msb-white1", "rowBytes": 100,
            "pageID": frame.pageID.uuidString, "revision": frame.revision, "hash": frame.hash, "frameURL": frameURL,
            "pollSeconds": metadata.pollSeconds, "pages": metadata.pages.map { ["id": $0.id.uuidString, "name": $0.name] },
            "taskIDs": frame.taskIDs.map(\.uuidString),
            "focusedTaskID": metadata.focusedTaskID.map { $0.uuidString as Any } ?? NSNull()]
        if let transferID { result["transferID"] = transferID.uuidString }
        return result
    }
}

enum SyncTransferState: String, Codable {
    case claimed, downloaded, refreshing, displayed, failed
}

struct SyncTransfer: Codable {
    var id: UUID
    var content: QueuedSyncFrame
    var state: SyncTransferState
    var claimedAt: Date
    var leaseExpiresAt: Date
}

struct SyncTransferReceipt: Codable {
    var id: UUID
    var pageID: UUID
    var revision: Int
    var hash: String
    var state: SyncTransferState

    func matches(id: UUID, pageID: UUID, revision: Int, hash: String) -> Bool {
        self.id == id && self.pageID == pageID && self.revision == revision && self.hash == hash
    }
}

enum FrameSyncError: LocalizedError {
    case invalid(String)
    case pairingChanged
    case staleTransfer
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .pairingChanged: return "同步状态属于其他配对密钥，请重新发布画面。"
        case .staleTransfer: return "传输已过期，或回执与领取的画面不匹配。请重新领取。"
        }
    }
}

/// A value-type queue: staging never mutates the transfer already owned by the device.
struct FrameSyncQueue {
    static let leaseDuration: TimeInterval = 180
    private static let maximumPNGBytes = 4 * 1024 * 1024
    private static let maximumStateBytes = 20 * 1024 * 1024
    enum RetryReason: String, Codable { case failed, expired }
    private struct SavedState: Codable {
        var version = 1
        var pairingDigest: String
        var pending: QueuedSyncFrame?
        var inFlight: SyncTransfer?
        var confirmed: SyncTransfer?
        var completed: [SyncTransferReceipt]
        var lastDisplayConfirmedAt: Date?
        var retryReason: RetryReason?
        var revisionWatermark: Int?
    }

    private(set) var pairingDigest: String
    private(set) var pending: QueuedSyncFrame?
    private(set) var inFlight: SyncTransfer?
    private(set) var confirmed: SyncTransfer?
    private(set) var completed: [SyncTransferReceipt] = []
    private(set) var lastDisplayConfirmedAt: Date?
    private(set) var retryReason: RetryReason?
    // Device error text is transient; it is never written to the key-free state file.
    private(set) var failureMessage: String?
    private var revisionWatermark = 0

    init(pairingToken: String) {
        pairingDigest = Self.digest(pairingToken)
    }

    init(data: Data, pairingToken: String, now: Date = Date()) throws {
        guard data.count <= Self.maximumStateBytes else { throw FrameSyncError.invalid("同步状态文件超过允许大小。") }
        let saved = try JSONDecoder().decode(SavedState.self, from: data)
        guard saved.version == 1 else { throw FrameSyncError.invalid("同步状态版本不受支持。") }
        guard saved.pairingDigest == Self.digest(pairingToken) else { throw FrameSyncError.pairingChanged }
        pairingDigest = saved.pairingDigest
        pending = saved.pending
        inFlight = saved.inFlight
        confirmed = saved.confirmed
        completed = saved.completed
        lastDisplayConfirmedAt = saved.lastDisplayConfirmedAt
        retryReason = saved.retryReason
        revisionWatermark = saved.revisionWatermark ?? 0
        revisionWatermark = maximumRevision
        try validate(now: now)
        _ = expireLease(now: now)
    }

    var latestContent: QueuedSyncFrame? { pending ?? inFlight?.content ?? confirmed?.content }
    func isPaired(with token: String) -> Bool { pairingDigest == Self.digest(token) }
    var maximumRevision: Int {
        max(revisionWatermark, max([pending?.frame.revision, inFlight?.content.frame.revision, confirmed?.content.frame.revision].compactMap { $0 }.max() ?? 0,
            completed.map(\.revision).max() ?? 0))
    }

    func encoded(now: Date = Date()) throws -> Data {
        try validate(now: now)
        let saved = SavedState(pairingDigest: pairingDigest, pending: pending, inFlight: inFlight, confirmed: confirmed,
                               completed: completed, lastDisplayConfirmedAt: lastDisplayConfirmedAt, retryReason: retryReason,
                               revisionWatermark: maximumRevision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= Self.maximumStateBytes else { throw FrameSyncError.invalid("同步状态文件超过允许大小。") }
        return data
    }

    @discardableResult mutating func stage(_ content: QueuedSyncFrame, force: Bool = false) throws -> Bool {
        try Self.validate(content)
        if !force {
            if let pending, pending.representsSameContent(as: content) { return false }
            if let inFlight, inFlight.content.representsSameContent(as: content) {
                pending = nil; retryReason = nil; failureMessage = nil
                revisionWatermark = max(maximumRevision, content.frame.revision)
                return true
            }
            if inFlight == nil, let confirmed, confirmed.content.representsSameContent(as: content) {
                pending = nil; retryReason = nil; failureMessage = nil
                revisionWatermark = max(maximumRevision, content.frame.revision)
                return true
            }
        }
        pending = content
        revisionWatermark = max(maximumRevision, content.frame.revision)
        retryReason = nil; failureMessage = nil
        return true
    }

    mutating func cancelPending() { revisionWatermark = maximumRevision; pending = nil; retryReason = nil; failureMessage = nil }
    mutating func prepareRetry() { retryReason = nil; failureMessage = nil }

    @discardableResult mutating func expireLease(now: Date) -> Bool {
        guard let transfer = inFlight, now >= transfer.leaseExpiresAt else { return false }
        // A newer edit wins over the expired raster. Old ACKs no longer have an active ID.
        if pending == nil { pending = transfer.content }
        inFlight = nil
        retryReason = .expired
        failureMessage = "设备未在 180 秒内确认显示；已保留最新画面，等待重新领取。"
        return true
    }

    mutating func claim(now: Date = Date()) -> SyncTransfer? {
        _ = expireLease(now: now)
        if let inFlight { return inFlight }
        if let pending {
            let transfer = SyncTransfer(id: UUID(), content: pending, state: .claimed, claimedAt: now,
                                        leaseExpiresAt: now.addingTimeInterval(Self.leaseDuration))
            self.pending = nil; inFlight = transfer; retryReason = nil; failureMessage = nil
            return transfer
        }
        // Reusing the completed ID keeps normal polling out of the busy phase.
        return confirmed
    }

    mutating func acknowledge(id: UUID, pageID: UUID, revision: Int, hash: String, state: SyncTransferState,
                              error: String? = nil, now: Date = Date()) throws {
        guard state != .claimed else { throw FrameSyncError.invalid("设备回执状态无效。") }
        _ = expireLease(now: now)
        guard var transfer = inFlight, transfer.id == id else {
            if let confirmed, confirmed.id == id,
               confirmed.content.frame.pageID == pageID, confirmed.content.frame.revision == revision,
               confirmed.content.frame.hash == hash, [.downloaded, .refreshing, .displayed].contains(state) { return }
            if let receipt = completed.first(where: { $0.matches(id: id, pageID: pageID, revision: revision, hash: hash) }),
               state == receipt.state || state == .downloaded || state == .refreshing { return }
            throw FrameSyncError.staleTransfer
        }
        let frame = transfer.content.frame
        guard frame.pageID == pageID, frame.revision == revision, frame.hash == hash else { throw FrameSyncError.staleTransfer }
        switch state {
        case .downloaded:
            if transfer.state == .claimed {
                transfer.state = .downloaded; transfer.leaseExpiresAt = now.addingTimeInterval(Self.leaseDuration)
                inFlight = transfer
            }
        case .refreshing:
            if transfer.state != .refreshing {
                transfer.state = .refreshing; transfer.leaseExpiresAt = now.addingTimeInterval(Self.leaseDuration)
                inFlight = transfer
            }
        case .displayed:
            transfer.state = .displayed
            confirmed = transfer; lastDisplayConfirmedAt = now; inFlight = nil
            retryReason = nil; failureMessage = nil
            remember(transfer, state: .displayed)
        case .failed:
            if pending == nil { pending = transfer.content }
            inFlight = nil; retryReason = .failed
            failureMessage = error?.isEmpty == false ? String(error!.prefix(300)) : "设备未能完成刷新，尚未确认新画面显示。"
            remember(transfer, state: .failed)
        case .claimed: break
        }
    }

    private mutating func remember(_ transfer: SyncTransfer, state: SyncTransferState) {
        let frame = transfer.content.frame
        completed.removeAll { $0.id == transfer.id }
        completed.append(SyncTransferReceipt(id: transfer.id, pageID: frame.pageID, revision: frame.revision, hash: frame.hash, state: state))
        if completed.count > 64 { completed.removeFirst(completed.count - 64) }
    }

    private func validate(now: Date) throws {
        guard revisionWatermark >= 0, revisionWatermark < Int.max - 1 else { throw FrameSyncError.invalid("同步版本无效。") }
        if let pending { try Self.validate(pending) }
        if let inFlight {
            try Self.validate(inFlight.content)
            guard [.claimed, .downloaded, .refreshing].contains(inFlight.state),
                  inFlight.claimedAt.timeIntervalSince1970.isFinite, inFlight.leaseExpiresAt.timeIntervalSince1970.isFinite,
                  inFlight.leaseExpiresAt >= inFlight.claimedAt,
                  inFlight.leaseExpiresAt <= now.addingTimeInterval(Self.leaseDuration * 2) else {
                throw FrameSyncError.invalid("同步传输的租约或阶段无效。")
            }
        }
        if let confirmed {
            try Self.validate(confirmed.content)
            guard confirmed.state == .displayed, lastDisplayConfirmedAt?.timeIntervalSince1970.isFinite == true else {
                throw FrameSyncError.invalid("同步确认记录无效。")
            }
        } else if lastDisplayConfirmedAt != nil { throw FrameSyncError.invalid("同步确认缺少对应画面。") }
        guard completed.count <= 64, Set(completed.map(\.id)).count == completed.count,
              completed.allSatisfy({ [.displayed, .failed].contains($0.state) && $0.revision >= 0 && Self.validHash($0.hash) }) else {
            throw FrameSyncError.invalid("同步回执记录无效。")
        }
    }

    private static func validate(_ content: QueuedSyncFrame) throws {
        let frame = content.frame
        let png = frame.pngData
        guard frame.revision >= 0, frame.revision < Int.max - 1,
              frame.bitmapData.count == 48_000, validHash(frame.hash), digest(frame.bitmapData) == frame.hash,
              frame.taskIDs.count <= 96, Set(frame.taskIDs).count == frame.taskIDs.count,
              frame.generatedAt.timeIntervalSince1970.isFinite,
              png.count >= 33, png.count <= maximumPNGBytes,
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              Array(png[12..<16]) == Array("IHDR".utf8),
              Array(png[16..<24]) == [0, 0, 3, 32, 0, 0, 1, 224],
              (1...24).contains(content.metadata.pages.count),
              Set(content.metadata.pages.map(\.id)).count == content.metadata.pages.count,
              content.metadata.pages.contains(where: { $0.id == frame.pageID }),
              content.metadata.pages.allSatisfy({ $0.name.utf8.count <= 4096 }),
              (5...3600).contains(content.metadata.pollSeconds),
              content.metadata.focusedTaskID.map({ frame.taskIDs.contains($0) }) ?? true else {
            throw FrameSyncError.invalid("同步画面的尺寸、哈希或清单无效。")
        }
        let manifest = try JSONSerialization.data(withJSONObject: content.manifest(frameURL: "/api/sync/frame.bin", transferID: UUID()))
        guard manifest.count <= 65_536 else { throw FrameSyncError.invalid("设备同步清单超过 64 KiB；请缩短页面名称。") }
    }

    private static func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
