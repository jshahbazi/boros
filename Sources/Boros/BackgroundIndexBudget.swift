import Foundation
import CryptoKit

// Immutable declarations and pure accounting/clock decisions. MemoryStore
// resamples the real clock under its mutex and commits work with aggregate
// totals before source access, inference or sidecar publication.

func backgroundIndexIdentifierEqual(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
}
func backgroundIndexIdentifierEqual(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (.none, .none): return true
    case (.some(let left), .some(let right)): return backgroundIndexIdentifierEqual(left, right)
    default: return false
    }
}

enum BackgroundIndexBudgetError: Error, Equatable {
    case invalid, exhausted, conflict, scopeMismatch, inactive, clockUnavailable, adapterViolation
    var failureCode: String {
        switch self {
        case .invalid, .conflict: return "background_index_accounting_failed"
        case .exhausted: return "background_index_budget_exceeded"
        case .scopeMismatch: return "background_index_scope_mismatch"
        case .inactive: return "background_index_inactive"
        case .clockUnavailable: return "background_index_clock_unavailable"
        case .adapterViolation: return "background_index_adapter_violation"
        }
    }
}

protocol BackgroundIndexValidated {
    func validate() throws
}

enum BackgroundIndexCanonical {
    static let maximumSnapshotBytes = 65_536
    static let maximumEvidenceBytes = 32_768
    static let maximumCanonicalRecordBytes = 262_144
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { sha256(try data(value)) }
    // Canonical re-encoding rejects unknown fields and alternate encodings
    // without a second permissive archive contract.
    static func decode<T: Codable & BackgroundIndexValidated>(_ type: T.Type, bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximumCanonicalRecordBytes else { throw BackgroundIndexBudgetError.invalid }
        let value = try JSONDecoder().decode(type, from: bytes)
        try value.validate()
        guard try data(value) == bytes else { throw BackgroundIndexBudgetError.invalid }
        return value
    }
    static func identifier(_ value: String, maximumBytes: Int = 256) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0") else {
            throw BackgroundIndexBudgetError.invalid
        }
    }
    static func hash(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BackgroundIndexBudgetError.invalid
        }
    }
}

enum BackgroundIndexResource: String, Codable, CaseIterable, Sendable {
    case rawSourceBytes, encoderCalls, encoderInputBytes, vectorBytes, metadataRows, sourceJobs
}

struct BackgroundIndexResources: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let rawSourceBytes: Int
    let encoderCalls: Int
    let encoderInputBytes: Int
    let vectorBytes: Int
    let metadataRows: Int
    let sourceJobs: Int

    init(rawSourceBytes: Int = 0, encoderCalls: Int = 0, encoderInputBytes: Int = 0,
         vectorBytes: Int = 0, metadataRows: Int = 0, sourceJobs: Int = 0) {
        self.rawSourceBytes = rawSourceBytes; self.encoderCalls = encoderCalls
        self.encoderInputBytes = encoderInputBytes; self.vectorBytes = vectorBytes
        self.metadataRows = metadataRows; self.sourceJobs = sourceJobs
    }
    static let zero = Self()
    static let developmentCaps = Self(rawSourceBytes: 512 * 1_048_576, encoderCalls: 4_096,
        encoderInputBytes: 16 * 1_048_576, vectorBytes: 32 * 1_048_576, metadataRows: 100_000, sourceJobs: 4_096)

    subscript(_ resource: BackgroundIndexResource) -> Int {
        switch resource {
        case .rawSourceBytes: return rawSourceBytes
        case .encoderCalls: return encoderCalls
        case .encoderInputBytes: return encoderInputBytes
        case .vectorBytes: return vectorBytes
        case .metadataRows: return metadataRows
        case .sourceJobs: return sourceJobs
        }
    }
    private init(_ values: [Int]) {
        self.init(rawSourceBytes: values[0], encoderCalls: values[1], encoderInputBytes: values[2],
            vectorBytes: values[3], metadataRows: values[4], sourceJobs: values[5])
    }
    func validate() throws {
        guard BackgroundIndexResource.allCases.allSatisfy({ self[$0] >= 0 }) else { throw BackgroundIndexBudgetError.invalid }
    }
    func adding(_ other: Self) throws -> Self {
        try validate(); try other.validate()
        return Self(try BackgroundIndexResource.allCases.map { resource in
            let (sum, overflow) = self[resource].addingReportingOverflow(other[resource])
            guard !overflow else { throw BackgroundIndexBudgetError.invalid }; return sum
        })
    }
    func subtracting(_ other: Self) throws -> Self {
        try validate(); try other.validate()
        return Self(try BackgroundIndexResource.allCases.map { resource in
            guard self[resource] >= other[resource] else { throw BackgroundIndexBudgetError.invalid }
            return self[resource] - other[resource]
        })
    }
    func fits(within cap: Self) -> Bool {
        BackgroundIndexResource.allCases.allSatisfy { self[$0] >= 0 && cap[$0] >= 0 && self[$0] <= cap[$0] }
    }
    var isZero: Bool { self == .zero }
}

struct BackgroundIndexLimits: Codable, Equatable, Sendable, BackgroundIndexValidated {
    static let durationNanoseconds: UInt64 = 86_400_000_000_000
    static let durationMilliseconds: Int64 = 86_400_000
    let version: String
    let resources: BackgroundIndexResources
    let windowNanoseconds: UInt64

    init(resources: BackgroundIndexResources = .developmentCaps, version: String = "background-index-day-v1",
         windowNanoseconds: UInt64 = Self.durationNanoseconds) {
        self.version = version; self.resources = resources; self.windowNanoseconds = windowNanoseconds
    }
    static let development = Self()
    func validate() throws {
        try resources.validate()
        guard backgroundIndexIdentifierEqual(version, "background-index-day-v1"),
              windowNanoseconds == Self.durationNanoseconds,
              resources.fits(within: .developmentCaps) else { throw BackgroundIndexBudgetError.invalid }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.version, right.version) && left.resources == right.resources
            && left.windowNanoseconds == right.windowNanoseconds
    }
}

/// Int64-compatible ticks and integer UTC milliseconds have one exact durable
/// representation. The integration adapter maps EpisodeClockSnapshot into this.
struct BackgroundIndexClockSnapshot: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let domain: String
    let continuousNanoseconds: UInt64
    let utcMilliseconds: Int64

    init(domain: String, continuousNanoseconds: UInt64, utcMilliseconds: Int64) {
        self.domain = domain; self.continuousNanoseconds = continuousNanoseconds; self.utcMilliseconds = utcMilliseconds
    }
    init(domain: String, continuousNanoseconds: UInt64, utc: Date) throws {
        let milliseconds = (utc.timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else {
            throw BackgroundIndexBudgetError.clockUnavailable
        }
        self.init(domain: domain, continuousNanoseconds: continuousNanoseconds, utcMilliseconds: Int64(milliseconds))
        try validate()
    }
    func validate() throws {
        try BackgroundIndexCanonical.identifier(domain)
        guard continuousNanoseconds > 0, continuousNanoseconds <= UInt64(Int64.max), utcMilliseconds >= 0 else {
            throw BackgroundIndexBudgetError.clockUnavailable
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.domain, right.domain) && left.continuousNanoseconds == right.continuousNanoseconds
            && left.utcMilliseconds == right.utcMilliseconds
    }
}
protocol BackgroundIndexClockSource: AnyObject { func now() throws -> BackgroundIndexClockSnapshot }

struct BackgroundIndexSourceBinding: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let version: String
    let source: BackgroundIndexSourceReference
    let sourceReferenceSHA256: String
    let offset: Int
    let byteCount: Int
    let chunkBytes: Int?
    let encoderDimension: Int?
    let requiresFinalSeal: Bool
    var projectID: String { source.projectID }
    var conversationID: String { source.conversationID }
    var eventID: String { source.eventID }
    var sourceSHA256: String { source.digest }
    var sourceSequence: Int { source.sequence }
    var sourceByteCount: Int { source.byteCount }
    init(source: BackgroundIndexSourceReference, offset: Int, byteCount: Int,
         chunkBytes: Int? = nil, encoderDimension: Int? = nil, requiresFinalSeal: Bool = false) throws {
        self.version = BackgroundWorkerRawRules.version; self.source = source
        self.sourceReferenceSHA256 = try source.canonicalDigest(); self.offset = offset; self.byteCount = byteCount
        self.chunkBytes = chunkBytes; self.encoderDimension = encoderDimension; self.requiresFinalSeal = requiresFinalSeal
        try validate()
    }
    func validate() throws {
        try source.validate()
        guard backgroundIndexIdentifierEqual(version, BackgroundWorkerRawRules.version),
              backgroundIndexIdentifierEqual(sourceReferenceSHA256, try source.canonicalDigest()),
              offset >= 0, offset <= sourceByteCount, byteCount >= 0, byteCount <= sourceByteCount - offset else {
            throw BackgroundIndexBudgetError.invalid
        }
        if let chunkBytes, let encoderDimension {
            guard (64...4096).contains(chunkBytes), (1...8192).contains(encoderDimension),
                  sourceByteCount > 0, offset < sourceByteCount,
                  byteCount == min(chunkBytes, sourceByteCount - offset),
                  requiresFinalSeal == (byteCount == sourceByteCount - offset) else { throw BackgroundIndexBudgetError.invalid }
        } else {
            guard chunkBytes == nil, encoderDimension == nil, offset == 0, byteCount == sourceByteCount,
                  !requiresFinalSeal else { throw BackgroundIndexBudgetError.invalid }
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.version, right.version) && left.source == right.source
            && backgroundIndexIdentifierEqual(left.sourceReferenceSHA256, right.sourceReferenceSHA256)
            && left.offset == right.offset && left.byteCount == right.byteCount && left.chunkBytes == right.chunkBytes
            && left.encoderDimension == right.encoderDimension && left.requiresFinalSeal == right.requiresFinalSeal
    }
}

/// Encodes exactly the complete payload-free MemorySourceReference keys while
/// keeping the accounting contract independent of SQLite and application types.
struct BackgroundIndexSourceReference: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let sequence: Int
    let eventID: String
    let conversationID: String
    let projectID: String
    let role: String
    let status: String
    let createdAt: String
    let digest: String
    let byteCount: Int
    func validate() throws {
        for value in [eventID, conversationID, projectID, createdAt] { try BackgroundIndexCanonical.identifier(value) }
        try BackgroundIndexCanonical.hash(digest)
        guard sequence > 0, (0...4_194_304).contains(byteCount), ["human", "assistant"].contains(role),
              ["complete", "partial", "failed", "cancelled"].contains(status) else { throw BackgroundIndexBudgetError.invalid }
        guard byteCount != 0 || digest == BackgroundIndexCanonical.sha256(Data()) else { throw BackgroundIndexBudgetError.invalid }
    }
    func canonicalData() throws -> Data { try validate(); return try BackgroundIndexCanonical.data(self) }
    func canonicalDigest() throws -> String { BackgroundIndexCanonical.sha256(try canonicalData()) }
    static func == (left: Self, right: Self) -> Bool {
        left.sequence == right.sequence && backgroundIndexIdentifierEqual(left.eventID, right.eventID)
            && backgroundIndexIdentifierEqual(left.conversationID, right.conversationID)
            && backgroundIndexIdentifierEqual(left.projectID, right.projectID) && backgroundIndexIdentifierEqual(left.role, right.role)
            && backgroundIndexIdentifierEqual(left.status, right.status) && backgroundIndexIdentifierEqual(left.createdAt, right.createdAt)
            && backgroundIndexIdentifierEqual(left.digest, right.digest) && left.byteCount == right.byteCount
    }
}

enum BackgroundWorkerRawRules {
    static let version = "background-bounded-pages-v1"
    static let sealPageBytes = 4096
    private static func add(_ left: Int, _ right: Int) throws -> Int {
        guard left >= 0, right >= 0 else { throw BackgroundIndexBudgetError.invalid }
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw BackgroundIndexBudgetError.invalid }; return result
    }
    private static func multiply(_ left: Int, _ right: Int) throws -> Int {
        guard left >= 0, right >= 0 else { throw BackgroundIndexBudgetError.invalid }
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw BackgroundIndexBudgetError.invalid }; return result
    }
    static func sealPageCount(sourceBytes: Int) throws -> Int {
        guard (1...4_194_304).contains(sourceBytes) else { throw BackgroundIndexBudgetError.invalid }
        return try add(sourceBytes / (sealPageBytes - 3), 1)
    }
    static func initialSeal(source: BackgroundIndexSourceReference) throws -> BackgroundIndexResources {
        try source.validate()
        let pages = try sealPageCount(sourceBytes: source.byteCount)
        return BackgroundIndexResources(rawSourceBytes: try multiply(2, add(source.byteCount, multiply(4, pages))),
            metadataRows: try add(pages, 2))
    }
    static func chunkAttempt(source: BackgroundIndexSourceReference, offset: Int, chunkBytes: Int,
                             dimension: Int) throws -> BackgroundIndexResources {
        try source.validate()
        guard source.byteCount > 0, offset >= 0, offset < source.byteCount, (64...4096).contains(chunkBytes),
              (1...8192).contains(dimension) else { throw BackgroundIndexBudgetError.invalid }
        let length = min(chunkBytes, source.byteCount - offset)
        let page = BackgroundIndexResources(rawSourceBytes: try multiply(4, add(length, 1)), encoderCalls: 1,
            encoderInputBytes: length, vectorBytes: try multiply(4, dimension), metadataRows: 5)
        return length == source.byteCount - offset ? try page.adding(initialSeal(source: source)) : page
    }
    static func emptySource(source: BackgroundIndexSourceReference) throws -> BackgroundIndexResources {
        try source.validate(); guard source.byteCount == 0 else { throw BackgroundIndexBudgetError.invalid }
        return BackgroundIndexResources(metadataRows: 5)
    }
}

enum BackgroundIndexMetadataTarget: String, Codable, Sendable {
    case captureSourceFrontier, scopeCursor, sourceManifest, pendingJobPeek, scheduleSources
}

struct BackgroundIndexMetadataDescriptor: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let target: BackgroundIndexMetadataTarget
    let afterSequence: Int
    // nil means capture-current only; all subsequent bounds are immutable.
    let throughSequence: Int?
    let limit: Int
    // scheduleSources binds the canonical ordered actual source-reference list.
    let sourceReferencesSHA256: String?
    func validate() throws {
        guard afterSequence >= 0, limit > 0, limit <= 4_096 else { throw BackgroundIndexBudgetError.invalid }
        if target == .captureSourceFrontier {
            guard afterSequence == 0, limit == 1, throughSequence == nil, sourceReferencesSHA256 == nil else {
                throw BackgroundIndexBudgetError.invalid
            }
        } else {
            guard let throughSequence, throughSequence >= afterSequence else { throw BackgroundIndexBudgetError.invalid }
        }
        if target == .scheduleSources {
            guard let sourceReferencesSHA256 else { throw BackgroundIndexBudgetError.invalid }
            try BackgroundIndexCanonical.hash(sourceReferencesSHA256)
        } else {
            guard sourceReferencesSHA256 == nil else { throw BackgroundIndexBudgetError.invalid }
        }
        if target == .scopeCursor || target == .pendingJobPeek {
            guard afterSequence == 0, limit == 1 else { throw BackgroundIndexBudgetError.invalid }
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        left.target == right.target && left.afterSequence == right.afterSequence
            && left.throughSequence == right.throughSequence && left.limit == right.limit
            && backgroundIndexIdentifierEqual(left.sourceReferencesSHA256, right.sourceReferencesSHA256)
    }
}

enum BackgroundIndexSourceOperation: String, Codable, Sendable {
    case initialSeal, chunkAttempt, emptySource
}

enum BackgroundIndexOperationDescriptor: Codable, Equatable, Sendable, BackgroundIndexValidated {
    case publicEncoderProbe
    case metadataFrontier(BackgroundIndexMetadataDescriptor)
    case source(BackgroundIndexSourceOperation, BackgroundIndexSourceBinding)

    static let publicProbeVersion = "public-two-sentences-v1"
    static let publicProbeSentences = ["The bicycle has two wheels.", "Clouds can bring rain to a dry garden."]
    static var publicProbeData: Data { get throws { try BackgroundIndexCanonical.data(publicProbeSentences) } }
    static var publicProbeSHA256: String { get throws { BackgroundIndexCanonical.sha256(try publicProbeData) } }
    static let publicProbeInputBytes = 65
    func validate() throws {
        switch self {
        case .publicEncoderProbe: break
        case .metadataFrontier(let descriptor): try descriptor.validate()
        case .source(_, let source): try source.validate()
        }
    }
    // An explicit tagged representation keeps archive recognition stable.
    private enum CodingKeys: String, CodingKey { case version, purpose, probeVersion, probeSHA256, metadata, operation, source }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .version) == "background-index-operation-v1" else { throw BackgroundIndexBudgetError.invalid }
        switch try values.decode(String.self, forKey: .purpose) {
        case "publicEncoderProbe":
            guard try values.decode(String.self, forKey: .probeVersion) == Self.publicProbeVersion,
                  try values.decode(String.self, forKey: .probeSHA256) == Self.publicProbeSHA256 else { throw BackgroundIndexBudgetError.invalid }
            self = .publicEncoderProbe
        case "metadataFrontier": self = .metadataFrontier(try values.decode(BackgroundIndexMetadataDescriptor.self, forKey: .metadata))
        case "source": self = .source(try values.decode(BackgroundIndexSourceOperation.self, forKey: .operation),
            try values.decode(BackgroundIndexSourceBinding.self, forKey: .source))
        default: throw BackgroundIndexBudgetError.invalid
        }
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("background-index-operation-v1", forKey: .version)
        switch self {
        case .publicEncoderProbe:
            try values.encode("publicEncoderProbe", forKey: .purpose)
            try values.encode(Self.publicProbeVersion, forKey: .probeVersion)
            try values.encode(Self.publicProbeSHA256, forKey: .probeSHA256)
        case .metadataFrontier(let descriptor):
            try values.encode("metadataFrontier", forKey: .purpose); try values.encode(descriptor, forKey: .metadata)
        case .source(let operation, let source):
            try values.encode("source", forKey: .purpose); try values.encode(operation, forKey: .operation); try values.encode(source, forKey: .source)
        }
    }
}

struct BackgroundIndexBinding: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let version: String
    let projectID: String?
    // Public probes have a pre-probe adapter identity but no final fingerprint.
    let indexFingerprint: String?
    let adapterIdentity: String
    let descriptor: BackgroundIndexOperationDescriptor
    init(projectID: String?, indexFingerprint: String?, adapterIdentity: String,
         descriptor: BackgroundIndexOperationDescriptor, version: String = "background-index-binding-v1") {
        self.version = version; self.projectID = projectID; self.indexFingerprint = indexFingerprint
        self.adapterIdentity = adapterIdentity; self.descriptor = descriptor
    }
    func validate() throws {
        guard backgroundIndexIdentifierEqual(version, "background-index-binding-v1") else { throw BackgroundIndexBudgetError.invalid }
        try BackgroundIndexCanonical.identifier(adapterIdentity, maximumBytes: 2_048)
        try descriptor.validate()
        switch descriptor {
        case .publicEncoderProbe:
            guard projectID == nil, indexFingerprint == nil else { throw BackgroundIndexBudgetError.invalid }
        case .metadataFrontier:
            guard let projectID, let indexFingerprint else { throw BackgroundIndexBudgetError.scopeMismatch }
            try BackgroundIndexCanonical.identifier(projectID); try BackgroundIndexCanonical.hash(indexFingerprint)
        case .source(_, let source):
            guard let projectID, backgroundIndexIdentifierEqual(projectID, source.projectID), let indexFingerprint else {
                throw BackgroundIndexBudgetError.scopeMismatch
            }
            try BackgroundIndexCanonical.hash(indexFingerprint)
        }
    }
    func canonicalData() throws -> Data { try validate(); return try BackgroundIndexCanonical.data(self) }
    func digest() throws -> String { BackgroundIndexCanonical.sha256(try canonicalData()) }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.version, right.version) && backgroundIndexIdentifierEqual(left.projectID, right.projectID)
            && backgroundIndexIdentifierEqual(left.indexFingerprint, right.indexFingerprint)
            && backgroundIndexIdentifierEqual(left.adapterIdentity, right.adapterIdentity) && left.descriptor == right.descriptor
    }
}

enum BackgroundIndexEncoderInput: String, Codable, Sendable { case notApplicable, unknown }
struct BackgroundIndexWorkSnapshot: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let payload: Data
    let sha256: String
    init(payload: Data) { self.payload = payload; self.sha256 = BackgroundIndexCanonical.sha256(payload) }
    func validate() throws {
        guard !payload.isEmpty, payload.count <= BackgroundIndexCanonical.maximumSnapshotBytes,
              sha256 == BackgroundIndexCanonical.sha256(payload) else { throw BackgroundIndexBudgetError.invalid }
    }
}
struct BackgroundIndexWorkRequest: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let id: String
    let binding: BackgroundIndexBinding
    let resources: BackgroundIndexResources
    let encoderInput: BackgroundIndexEncoderInput
    let snapshot: BackgroundIndexWorkSnapshot?
    func validate() throws {
        try BackgroundIndexCanonical.identifier(id); try binding.validate(); try resources.validate(); try snapshot?.validate()
        guard resources.fits(within: .developmentCaps), !resources.isZero,
              (resources.encoderCalls == 0 && encoderInput == .notApplicable && resources.encoderInputBytes == 0)
                || (resources.encoderCalls > 0 && encoderInput == .unknown && resources.encoderInputBytes > 0) else {
            throw BackgroundIndexBudgetError.invalid
        }
        switch binding.descriptor {
        case .publicEncoderProbe:
            guard resources == BackgroundIndexResources(encoderCalls: 2, encoderInputBytes: 65),
                  snapshot?.payload == (try BackgroundIndexOperationDescriptor.publicProbeData) else { throw BackgroundIndexBudgetError.invalid }
        case .metadataFrontier(let descriptor):
            if descriptor.target == .scheduleSources {
                guard let payload = snapshot?.payload else { throw BackgroundIndexBudgetError.invalid }
                let sources = try JSONDecoder().decode([BackgroundIndexSourceReference].self, from: payload)
                guard try BackgroundIndexCanonical.data(sources) == payload, sources.count == descriptor.limit,
                      BackgroundIndexCanonical.sha256(payload) == descriptor.sourceReferencesSHA256,
                      let projectID = binding.projectID, let through = descriptor.throughSequence else {
                    throw BackgroundIndexBudgetError.invalid
                }
                var sequence = descriptor.afterSequence
                var ids = Set<Data>()
                for source in sources {
                    try source.validate()
                    guard backgroundIndexIdentifierEqual(source.projectID, projectID), source.sequence > sequence,
                          source.sequence <= through, ids.insert(Data(source.eventID.utf8)).inserted else {
                        throw BackgroundIndexBudgetError.scopeMismatch
                    }
                    sequence = source.sequence
                }
                let (twice, overflow) = descriptor.limit.multipliedReportingOverflow(by: 2)
                let (rows, sumOverflow) = twice.addingReportingOverflow(1)
                guard !overflow, !sumOverflow,
                      resources == BackgroundIndexResources(metadataRows: rows, sourceJobs: descriptor.limit) else {
                    throw BackgroundIndexBudgetError.invalid
                }
            } else {
                let rows = descriptor.target == .sourceManifest ? descriptor.limit : 1
                guard snapshot == nil, resources == BackgroundIndexResources(metadataRows: rows) else {
                    throw BackgroundIndexBudgetError.invalid
                }
            }
        case .source(let operation, let source):
            guard snapshot?.payload == (try source.source.canonicalData()) else { throw BackgroundIndexBudgetError.invalid }
            switch operation {
            case .emptySource:
                guard source.chunkBytes == nil, source.encoderDimension == nil,
                      resources == (try BackgroundWorkerRawRules.emptySource(source: source.source)) else {
                    throw BackgroundIndexBudgetError.invalid
                }
            case .chunkAttempt:
                guard let chunkBytes = source.chunkBytes, let dimension = source.encoderDimension,
                      resources == (try BackgroundWorkerRawRules.chunkAttempt(source: source.source,
                        offset: source.offset, chunkBytes: chunkBytes, dimension: dimension)) else {
                    throw BackgroundIndexBudgetError.invalid
                }
            case .initialSeal:
                guard source.chunkBytes == nil, source.encoderDimension == nil,
                      resources == (try BackgroundWorkerRawRules.initialSeal(source: source.source)) else {
                    throw BackgroundIndexBudgetError.invalid
                }
            }
        }
    }
    // Storage may deduplicate the snapshot payload separately, retaining this
    // immutable canonical request metadata and its snapshot digest in work.
    func canonicalMetadataData() throws -> Data {
        try validate()
        return try BackgroundIndexCanonical.data(Metadata(id: id, binding: binding, resources: resources,
            encoderInput: encoderInput, snapshotSHA256: snapshot?.sha256))
    }
    func digest() throws -> String { BackgroundIndexCanonical.sha256(try canonicalMetadataData()) }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.id, right.id) && left.binding == right.binding && left.resources == right.resources
            && left.encoderInput == right.encoderInput && left.snapshot == right.snapshot
    }
    struct Metadata: Codable, Equatable, Sendable {
        let id: String
        let binding: BackgroundIndexBinding
        let resources: BackgroundIndexResources
        let encoderInput: BackgroundIndexEncoderInput
        let snapshotSHA256: String?
        static func == (left: Self, right: Self) -> Bool {
            backgroundIndexIdentifierEqual(left.id, right.id) && left.binding == right.binding
                && left.resources == right.resources && left.encoderInput == right.encoderInput
                && backgroundIndexIdentifierEqual(left.snapshotSHA256, right.snapshotSHA256)
        }
    }

    static func publicEncoderProbe(id: String, adapterIdentity: String) throws -> Self {
        let value = Self(id: id, binding: BackgroundIndexBinding(projectID: nil, indexFingerprint: nil,
            adapterIdentity: adapterIdentity, descriptor: .publicEncoderProbe),
            resources: BackgroundIndexResources(encoderCalls: 2, encoderInputBytes: 65), encoderInput: .unknown,
            snapshot: BackgroundIndexWorkSnapshot(payload: try BackgroundIndexOperationDescriptor.publicProbeData))
        try value.validate(); return value
    }
    static func initialSeal(id: String, source: BackgroundIndexSourceReference, indexFingerprint: String,
                            adapterIdentity: String) throws -> Self {
        try sourceRequest(id: id, source: source, indexFingerprint: indexFingerprint, adapterIdentity: adapterIdentity,
            operation: .initialSeal, sourceBinding: BackgroundIndexSourceBinding(source: source, offset: 0, byteCount: source.byteCount),
            resources: BackgroundWorkerRawRules.initialSeal(source: source))
    }
    static func chunkAttempt(id: String, source: BackgroundIndexSourceReference, offset: Int, chunkBytes: Int,
                             dimension: Int, indexFingerprint: String, adapterIdentity: String) throws -> Self {
        let resources = try BackgroundWorkerRawRules.chunkAttempt(source: source, offset: offset, chunkBytes: chunkBytes, dimension: dimension)
        let length = min(chunkBytes, source.byteCount - offset)
        return try sourceRequest(id: id, source: source, indexFingerprint: indexFingerprint, adapterIdentity: adapterIdentity,
            operation: .chunkAttempt, sourceBinding: BackgroundIndexSourceBinding(source: source, offset: offset, byteCount: length,
                chunkBytes: chunkBytes, encoderDimension: dimension, requiresFinalSeal: length == source.byteCount - offset), resources: resources)
    }
    static func emptySource(id: String, source: BackgroundIndexSourceReference, indexFingerprint: String,
                            adapterIdentity: String) throws -> Self {
        try sourceRequest(id: id, source: source, indexFingerprint: indexFingerprint, adapterIdentity: adapterIdentity,
            operation: .emptySource, sourceBinding: BackgroundIndexSourceBinding(source: source, offset: 0, byteCount: source.byteCount),
            resources: BackgroundWorkerRawRules.emptySource(source: source))
    }
    private static func sourceRequest(id: String, source: BackgroundIndexSourceReference, indexFingerprint: String,
                                      adapterIdentity: String, operation: BackgroundIndexSourceOperation,
                                      sourceBinding: BackgroundIndexSourceBinding, resources: BackgroundIndexResources) throws -> Self {
        let value = Self(id: id, binding: BackgroundIndexBinding(projectID: source.projectID, indexFingerprint: indexFingerprint,
            adapterIdentity: adapterIdentity, descriptor: .source(operation, sourceBinding)), resources: resources,
            encoderInput: resources.encoderCalls > 0 ? .unknown : .notApplicable,
            snapshot: BackgroundIndexWorkSnapshot(payload: try source.canonicalData()))
        try value.validate(); return value
    }
    static func metadata(id: String, projectID: String, indexFingerprint: String, adapterIdentity: String,
                         descriptor: BackgroundIndexMetadataDescriptor,
                         sourceReferences: [BackgroundIndexSourceReference]? = nil) throws -> Self {
        try descriptor.validate()
        let snapshot: BackgroundIndexWorkSnapshot?
        let resources: BackgroundIndexResources
        if descriptor.target == .scheduleSources {
            guard let sourceReferences else { throw BackgroundIndexBudgetError.invalid }
            snapshot = BackgroundIndexWorkSnapshot(payload: try BackgroundIndexCanonical.data(sourceReferences))
            let (twice, overflow) = descriptor.limit.multipliedReportingOverflow(by: 2)
            let (rows, sumOverflow) = twice.addingReportingOverflow(1)
            guard !overflow, !sumOverflow else { throw BackgroundIndexBudgetError.invalid }
            resources = BackgroundIndexResources(metadataRows: rows, sourceJobs: descriptor.limit)
        } else {
            guard sourceReferences == nil else { throw BackgroundIndexBudgetError.invalid }
            snapshot = nil; resources = BackgroundIndexResources(metadataRows: descriptor.target == .sourceManifest ? descriptor.limit : 1)
        }
        let value = Self(id: id, binding: BackgroundIndexBinding(projectID: projectID, indexFingerprint: indexFingerprint,
            adapterIdentity: adapterIdentity, descriptor: .metadataFrontier(descriptor)), resources: resources,
            encoderInput: .notApplicable, snapshot: snapshot)
        try value.validate(); return value
    }
}

/// On reboot, the first acceptable UTC sample establishes remaining time. This
/// anchor prevents subsequent wall-clock jumps in that boot from shortening it.
struct BackgroundIndexBootAnchor: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let domain: String
    let continuousNanoseconds: UInt64
    let establishedAgeNanoseconds: UInt64
    let requiresUTCForRollover: Bool
    func validate() throws {
        try BackgroundIndexCanonical.identifier(domain)
        guard continuousNanoseconds > 0, continuousNanoseconds <= UInt64(Int64.max),
              establishedAgeNanoseconds < BackgroundIndexLimits.durationNanoseconds else { throw BackgroundIndexBudgetError.invalid }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.domain, right.domain) && left.continuousNanoseconds == right.continuousNanoseconds
            && left.establishedAgeNanoseconds == right.establishedAgeNanoseconds
            && left.requiresUTCForRollover == right.requiresUTCForRollover
    }
}
enum BackgroundIndexWindowState: String, Codable, Sendable { case active, closed }
struct BackgroundIndexWindow: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let version: String
    let id: String
    let limits: BackgroundIndexLimits
    let state: BackgroundIndexWindowState
    let startedClock: BackgroundIndexClockSnapshot
    // A rollover during UTC regression uses the prior high-water as a minimum
    // new reboot baseline, while retaining the actual observed start clock.
    let utcRolloverBaselineMilliseconds: Int64
    let utcHighWaterMilliseconds: Int64
    let anchor: BackgroundIndexBootAnchor
    let lastClock: BackgroundIndexClockSnapshot
    let revision: Int
    let charged: BackgroundIndexResources
    let held: BackgroundIndexResources
    let unknownEncoderCalls: Int
    let closedClock: BackgroundIndexClockSnapshot?

    static func begin(id: String, limits: BackgroundIndexLimits, clock: BackgroundIndexClockSnapshot,
                      previousUTCHighWaterMilliseconds: Int64? = nil) throws -> Self {
        try limits.validate(); try clock.validate(); try BackgroundIndexCanonical.identifier(id)
        guard previousUTCHighWaterMilliseconds == nil || previousUTCHighWaterMilliseconds! >= 0 else {
            throw BackgroundIndexBudgetError.clockUnavailable
        }
        let baseline = max(clock.utcMilliseconds, previousUTCHighWaterMilliseconds ?? clock.utcMilliseconds)
        return Self(version: "background-index-window-v1", id: id, limits: limits, state: .active,
            startedClock: clock, utcRolloverBaselineMilliseconds: baseline, utcHighWaterMilliseconds: baseline,
            anchor: BackgroundIndexBootAnchor(domain: clock.domain, continuousNanoseconds: clock.continuousNanoseconds,
                establishedAgeNanoseconds: 0, requiresUTCForRollover: false), lastClock: clock, revision: 0,
            charged: .zero, held: .zero, unknownEncoderCalls: 0, closedClock: nil)
    }
    func validate() throws {
        try BackgroundIndexCanonical.identifier(id); try limits.validate(); try startedClock.validate()
        try lastClock.validate(); try anchor.validate(); try charged.validate(); try held.validate(); try closedClock?.validate()
        guard backgroundIndexIdentifierEqual(version, "background-index-window-v1"), revision >= 0,
              utcRolloverBaselineMilliseconds >= startedClock.utcMilliseconds,
              utcHighWaterMilliseconds >= utcRolloverBaselineMilliseconds,
              utcHighWaterMilliseconds >= lastClock.utcMilliseconds,
              backgroundIndexIdentifierEqual(anchor.domain, lastClock.domain), lastClock.continuousNanoseconds >= anchor.continuousNanoseconds,
              try charged.adding(held).fits(within: limits.resources), unknownEncoderCalls >= 0,
              unknownEncoderCalls == charged.encoderCalls,
              (state == .active && closedClock == nil) || (state == .closed && closedClock == lastClock) else {
            throw BackgroundIndexBudgetError.invalid
        }
        // The original boot has an exact immutable continuous-clock origin.
        // An inherited UTC age exists only after observing a different boot.
        // Keep these constraints here so runtime decoding and archive checks
        // cannot disagree about a clock anchor that would renew quota early.
        if backgroundIndexIdentifierEqual(anchor.domain, startedClock.domain) {
            guard anchor.continuousNanoseconds == startedClock.continuousNanoseconds,
                  anchor.establishedAgeNanoseconds == 0, !anchor.requiresUTCForRollover else {
                throw BackgroundIndexBudgetError.invalid
            }
        } else {
            guard anchor.requiresUTCForRollover else { throw BackgroundIndexBudgetError.invalid }
        }
    }
    func remaining() throws -> BackgroundIndexResources { try validate(); return try limits.resources.subtracting(charged.adding(held)) }
    private func replacing(clock: BackgroundIndexClockSnapshot? = nil, highWater: Int64? = nil,
                           anchor: BackgroundIndexBootAnchor? = nil, state: BackgroundIndexWindowState? = nil,
                           charged: BackgroundIndexResources? = nil, held: BackgroundIndexResources? = nil,
                           unknownEncoderCalls: Int? = nil, closedClock: BackgroundIndexClockSnapshot? = nil) throws -> Self {
        let (revision, overflow) = self.revision.addingReportingOverflow(1)
        guard !overflow else { throw BackgroundIndexBudgetError.invalid }
        let value = Self(version: version, id: id, limits: limits, state: state ?? self.state, startedClock: startedClock,
            utcRolloverBaselineMilliseconds: utcRolloverBaselineMilliseconds,
            utcHighWaterMilliseconds: highWater ?? utcHighWaterMilliseconds, anchor: anchor ?? self.anchor,
            lastClock: clock ?? lastClock, revision: revision, charged: charged ?? self.charged,
            held: held ?? self.held, unknownEncoderCalls: unknownEncoderCalls ?? self.unknownEncoderCalls,
            closedClock: closedClock ?? self.closedClock)
        try value.validate(); return value
    }
    func reserving(_ request: BackgroundIndexWorkRequest) throws -> Self {
        try validate(); try request.validate(); guard state == .active else { throw BackgroundIndexBudgetError.inactive }
        let held = try self.held.adding(request.resources)
        guard try charged.adding(held).fits(within: limits.resources) else { throw BackgroundIndexBudgetError.exhausted }
        return try replacing(held: held)
    }
    func arming(_ request: BackgroundIndexWorkRequest) throws -> Self {
        try validate(); try request.validate(); guard state == .active else { throw BackgroundIndexBudgetError.inactive }
        let held = try self.held.subtracting(request.resources), charged = try self.charged.adding(request.resources)
        let unknown = encoderUnknownCount(request)
        let (totalUnknown, overflow) = unknownEncoderCalls.addingReportingOverflow(unknown)
        guard !overflow else { throw BackgroundIndexBudgetError.invalid }
        return try replacing(charged: charged, held: held, unknownEncoderCalls: totalUnknown)
    }
    func releasingPrepared(_ request: BackgroundIndexWorkRequest) throws -> Self {
        try validate(); try request.validate()
        return try replacing(held: self.held.subtracting(request.resources))
    }
    func closing(at clock: BackgroundIndexClockSnapshot) throws -> Self {
        let decision = try observed(at: clock)
        guard decision.rolloverEligible else { throw BackgroundIndexBudgetError.inactive }
        return try decision.window.replacing(state: .closed, closedClock: clock)
    }
    private func encoderUnknownCount(_ request: BackgroundIndexWorkRequest) -> Int {
        request.encoderInput == .unknown ? request.resources.encoderCalls : 0
    }
    func observed(at clock: BackgroundIndexClockSnapshot) throws -> BackgroundIndexWindowDecision {
        try validate(); try clock.validate(); guard state == .active else { throw BackgroundIndexBudgetError.inactive }
        let highWater = max(utcHighWaterMilliseconds, clock.utcMilliseconds)
        let utcEligible = clock.utcMilliseconds >= utcHighWaterMilliseconds
            && clock.utcMilliseconds >= utcRolloverBaselineMilliseconds
            && clock.utcMilliseconds - utcRolloverBaselineMilliseconds >= BackgroundIndexLimits.durationMilliseconds
        if backgroundIndexIdentifierEqual(clock.domain, anchor.domain) {
            guard clock.continuousNanoseconds >= lastClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.clockUnavailable }
            let (elapsed, overflow) = anchor.establishedAgeNanoseconds.addingReportingOverflow(clock.continuousNanoseconds - anchor.continuousNanoseconds)
            guard !overflow else { throw BackgroundIndexBudgetError.clockUnavailable }
            let updated = try replacing(clock: clock, highWater: highWater)
            if elapsed >= limits.windowNanoseconds {
                if anchor.requiresUTCForRollover && !utcEligible {
                    return BackgroundIndexWindowDecision(window: updated, rolloverEligible: false, pauseReason: .clockUnavailable)
                }
                return BackgroundIndexWindowDecision(window: updated, rolloverEligible: true, pauseReason: nil)
            }
            return BackgroundIndexWindowDecision(window: updated, rolloverEligible: false,
                pauseReason: anchor.requiresUTCForRollover &&
                    (clock.utcMilliseconds < utcHighWaterMilliseconds || clock.utcMilliseconds < utcRolloverBaselineMilliseconds)
                    ? .clockUnavailable : nil)
        }
        // Reboot UTC regression retains the allowance. Starting a conservative
        // full-day anchor prevents a later in-boot UTC jump from granting quota.
        let utcValid = clock.utcMilliseconds >= utcHighWaterMilliseconds && clock.utcMilliseconds >= utcRolloverBaselineMilliseconds
        // A qualifying UTC age need not be converted to nanoseconds. Keeping
        // the multiplication below one day prevents malformed future dates
        // from trapping even before the owner rejects their observations.
        let age: UInt64 = utcValid && !utcEligible ? UInt64(clock.utcMilliseconds - utcRolloverBaselineMilliseconds) * 1_000_000 : 0
        let newAnchor = BackgroundIndexBootAnchor(domain: clock.domain, continuousNanoseconds: clock.continuousNanoseconds,
            establishedAgeNanoseconds: utcEligible ? 0 : min(age, limits.windowNanoseconds - 1), requiresUTCForRollover: true)
        let updated = try replacing(clock: clock, highWater: highWater, anchor: newAnchor)
        return BackgroundIndexWindowDecision(window: updated, rolloverEligible: utcEligible,
            pauseReason: utcValid ? nil : .clockUnavailable)
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.version, right.version) && backgroundIndexIdentifierEqual(left.id, right.id)
            && left.limits == right.limits && left.state == right.state && left.startedClock == right.startedClock
            && left.utcRolloverBaselineMilliseconds == right.utcRolloverBaselineMilliseconds
            && left.utcHighWaterMilliseconds == right.utcHighWaterMilliseconds && left.anchor == right.anchor
            && left.lastClock == right.lastClock && left.revision == right.revision && left.charged == right.charged
            && left.held == right.held && left.unknownEncoderCalls == right.unknownEncoderCalls && left.closedClock == right.closedClock
    }
}
enum BackgroundIndexPauseReason: String, Codable, Sendable { case notStarted, exhausted, clockUnavailable }
struct BackgroundIndexWindowDecision: Equatable, Sendable {
    let window: BackgroundIndexWindow
    let rolloverEligible: Bool
    let pauseReason: BackgroundIndexPauseReason?
}

enum BackgroundIndexWorkState: String, Codable, Sendable {
    case prepared, armed, submitted, completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch
    var wasArmed: Bool { self != .prepared && self != .cancelledBeforeDispatch }
}
enum BackgroundIndexWorkOutcome: String, Codable, Sendable { case completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch }

/// Content-free proof of the exact source/range and sidecar publication. A seal
/// describes a fresh traversal completed by this armed attempt, never a cache.
struct BackgroundIndexWorkerEvidence: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let version: String
    let sourceReferenceSHA256: String
    let offset: Int
    let byteCount: Int
    let textSHA256: String?
    let vectorByteCount: Int
    let publicationSequence: Int?
    let sourceSealedSHA256: String?
    let sourceSealedByteCount: Int?
    init(sourceReferenceSHA256: String, offset: Int, byteCount: Int, textSHA256: String? = nil,
         vectorByteCount: Int = 0, publicationSequence: Int? = nil, sourceSealedSHA256: String? = nil,
         sourceSealedByteCount: Int? = nil, version: String = "background-worker-evidence-v1") {
        self.version = version; self.sourceReferenceSHA256 = sourceReferenceSHA256; self.offset = offset
        self.byteCount = byteCount; self.textSHA256 = textSHA256; self.vectorByteCount = vectorByteCount
        self.publicationSequence = publicationSequence; self.sourceSealedSHA256 = sourceSealedSHA256
        self.sourceSealedByteCount = sourceSealedByteCount
    }
    func validate() throws {
        try BackgroundIndexCanonical.hash(sourceReferenceSHA256)
        if let textSHA256 { try BackgroundIndexCanonical.hash(textSHA256) }
        if let sourceSealedSHA256 { try BackgroundIndexCanonical.hash(sourceSealedSHA256) }
        guard backgroundIndexIdentifierEqual(version, "background-worker-evidence-v1"),
              offset >= 0, offset <= 4_194_304, byteCount >= 0, byteCount <= 4_194_304 - offset,
              vectorByteCount >= 0, vectorByteCount <= 4 * 8192, vectorByteCount % 4 == 0,
              publicationSequence == nil || publicationSequence! > 0,
              (sourceSealedSHA256 == nil) == (sourceSealedByteCount == nil),
              sourceSealedByteCount == nil || (0...4_194_304).contains(sourceSealedByteCount!) else {
            throw BackgroundIndexBudgetError.invalid
        }
    }
    func canonicalData() throws -> Data { try validate(); return try BackgroundIndexCanonical.data(self) }
    func validate(for request: BackgroundIndexWorkRequest) throws {
        try validate(); try request.validate()
        guard case .source(let operation, let binding) = request.binding.descriptor,
              backgroundIndexIdentifierEqual(sourceReferenceSHA256, binding.sourceReferenceSHA256),
              offset == binding.offset, byteCount <= binding.byteCount, vectorByteCount <= request.resources.vectorBytes else {
            throw BackgroundIndexBudgetError.invalid
        }
        func requireSeal() throws {
            guard backgroundIndexIdentifierEqual(sourceSealedSHA256, binding.sourceSHA256),
                  sourceSealedByteCount == binding.sourceByteCount else { throw BackgroundIndexBudgetError.invalid }
        }
        switch operation {
        case .initialSeal:
            guard offset == 0, byteCount == binding.sourceByteCount, textSHA256 == nil,
                  vectorByteCount == 0, publicationSequence == nil else { throw BackgroundIndexBudgetError.invalid }
            try requireSeal()
        case .chunkAttempt:
            guard byteCount > 0, textSHA256 != nil, publicationSequence != nil else { throw BackgroundIndexBudgetError.invalid }
            if binding.requiresFinalSeal {
                guard byteCount == binding.sourceByteCount - offset else { throw BackgroundIndexBudgetError.invalid }
                try requireSeal()
            } else {
                guard sourceSealedSHA256 == nil, sourceSealedByteCount == nil else { throw BackgroundIndexBudgetError.invalid }
            }
        case .emptySource:
            guard offset == 0, byteCount == 0, textSHA256 == nil, vectorByteCount == 0,
                  publicationSequence == nil, binding.sourceSHA256 == BackgroundIndexCanonical.sha256(Data()) else {
                throw BackgroundIndexBudgetError.invalid
            }
            try requireSeal()
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.version, right.version)
            && backgroundIndexIdentifierEqual(left.sourceReferenceSHA256, right.sourceReferenceSHA256)
            && left.offset == right.offset && left.byteCount == right.byteCount
            && backgroundIndexIdentifierEqual(left.textSHA256, right.textSHA256) && left.vectorByteCount == right.vectorByteCount
            && left.publicationSequence == right.publicationSequence
            && backgroundIndexIdentifierEqual(left.sourceSealedSHA256, right.sourceSealedSHA256)
            && left.sourceSealedByteCount == right.sourceSealedByteCount
    }
}

struct BackgroundIndexWorkSettlement: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let receiptID: String
    let outcome: BackgroundIndexWorkOutcome
    // Informational observed work never refunds an armed conservative charge.
    let observed: BackgroundIndexResources?
    let evidence: Data?
    let adapterViolation: Bool
    init(receiptID: String, outcome: BackgroundIndexWorkOutcome, observed: BackgroundIndexResources? = nil,
         evidence: Data? = nil, adapterViolation: Bool = false) {
        self.receiptID = receiptID; self.outcome = outcome; self.observed = observed; self.evidence = evidence; self.adapterViolation = adapterViolation
    }
    func validate() throws {
        try BackgroundIndexCanonical.identifier(receiptID); try observed?.validate()
        guard (evidence?.count ?? 0) <= BackgroundIndexCanonical.maximumEvidenceBytes else { throw BackgroundIndexBudgetError.invalid }
        guard outcome != .completed || !adapterViolation else { throw BackgroundIndexBudgetError.invalid }
        if outcome == .cancelledBeforeDispatch { guard observed == nil || observed == .zero, !adapterViolation else { throw BackgroundIndexBudgetError.invalid } }
    }
    func validate(for request: BackgroundIndexWorkRequest) throws {
        try validate(); try request.validate()
        if let observed, !observed.fits(within: request.resources), !adapterViolation { throw BackgroundIndexBudgetError.adapterViolation }
        if outcome == .completed, case .source = request.binding.descriptor {
            guard !adapterViolation, let evidence, !evidence.isEmpty else { throw BackgroundIndexBudgetError.invalid }
            let value = try BackgroundIndexCanonical.decode(BackgroundIndexWorkerEvidence.self, bytes: evidence)
            try value.validate(for: request)
        }
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.receiptID, right.receiptID) && left.outcome == right.outcome
            && left.observed == right.observed && left.evidence == right.evidence && left.adapterViolation == right.adapterViolation
    }
}
struct BackgroundIndexWorkRecord: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let windowID: String
    let request: BackgroundIndexWorkRequest
    let requestDigest: String
    let bindingDigest: String
    let state: BackgroundIndexWorkState
    let revision: Int
    let charged: BackgroundIndexResources
    let held: BackgroundIndexResources
    let createdClock: BackgroundIndexClockSnapshot
    let armedClock: BackgroundIndexClockSnapshot?
    let settlement: BackgroundIndexWorkSettlement?
    let recovered: Bool

    static func prepared(windowID: String, request: BackgroundIndexWorkRequest, clock: BackgroundIndexClockSnapshot) throws -> Self {
        try request.validate(); try clock.validate(); try BackgroundIndexCanonical.identifier(windowID)
        return Self(windowID: windowID, request: request, requestDigest: try request.digest(), bindingDigest: try request.binding.digest(),
            state: .prepared, revision: 0, charged: .zero, held: request.resources, createdClock: clock,
            armedClock: nil, settlement: nil, recovered: false)
    }
    func validate() throws {
        try BackgroundIndexCanonical.identifier(windowID); try request.validate(); try createdClock.validate(); try armedClock?.validate()
        try charged.validate(); try held.validate(); try settlement?.validate(for: request)
        guard revision >= 0, requestDigest == (try request.digest()), bindingDigest == (try request.binding.digest()) else { throw BackgroundIndexBudgetError.invalid }
        guard !recovered || state == .cancelledBeforeDispatch || state == .outcomeUnknown else { throw BackgroundIndexBudgetError.invalid }
        if state == .prepared {
            guard revision == 0, charged == .zero, held == request.resources, armedClock == nil, settlement == nil, !recovered else { throw BackgroundIndexBudgetError.invalid }
        } else if state == .cancelledBeforeDispatch {
            guard revision == 1, charged == .zero, held == .zero, armedClock == nil,
                  settlement?.outcome == .cancelledBeforeDispatch else { throw BackgroundIndexBudgetError.invalid }
        } else {
            guard charged == request.resources, held == .zero, let armedClock,
                  backgroundIndexIdentifierEqual(armedClock.domain, createdClock.domain),
                  armedClock.continuousNanoseconds >= createdClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.invalid }
            switch state {
            case .armed: guard revision == 1, settlement == nil else { throw BackgroundIndexBudgetError.invalid }
            case .submitted: guard revision == 2, settlement == nil else { throw BackgroundIndexBudgetError.invalid }
            case .completed: guard (2...3).contains(revision), settlement?.outcome == .completed else { throw BackgroundIndexBudgetError.invalid }
            case .failedConfirmed: guard (2...3).contains(revision), settlement?.outcome == .failedConfirmed else { throw BackgroundIndexBudgetError.invalid }
            case .outcomeUnknown: guard (2...3).contains(revision), settlement?.outcome == .outcomeUnknown else { throw BackgroundIndexBudgetError.invalid }
            default: throw BackgroundIndexBudgetError.invalid
            }
        }
    }
    func accepts(bindingDigest: String) throws {
        try validate(); guard backgroundIndexIdentifierEqual(self.bindingDigest, bindingDigest) else { throw BackgroundIndexBudgetError.conflict }
    }
    func armed(at clock: BackgroundIndexClockSnapshot) throws -> Self {
        try validate(); try clock.validate(); guard state == .prepared else { throw BackgroundIndexBudgetError.inactive }
        guard backgroundIndexIdentifierEqual(clock.domain, createdClock.domain), clock.continuousNanoseconds >= createdClock.continuousNanoseconds else {
            throw BackgroundIndexBudgetError.clockUnavailable
        }
        return try replacing(state: .armed, charged: request.resources, held: .zero, armedClock: clock)
    }
    func submitted() throws -> Self {
        try validate(); guard state == .armed else { throw BackgroundIndexBudgetError.inactive }
        return try replacing(state: .submitted)
    }
    func settled(_ settlement: BackgroundIndexWorkSettlement, recovered: Bool = false) throws -> Self {
        try validate(); try settlement.validate(for: request)
        if let existing = self.settlement {
            guard existing == settlement else { throw BackgroundIndexBudgetError.conflict }; return self
        }
        if state == .prepared {
            guard settlement.outcome == .cancelledBeforeDispatch else { throw BackgroundIndexBudgetError.inactive }
            return try replacing(state: .cancelledBeforeDispatch, held: .zero, settlement: settlement, recovered: recovered)
        }
        guard state == .armed || state == .submitted, settlement.outcome != .cancelledBeforeDispatch else { throw BackgroundIndexBudgetError.inactive }
        let state: BackgroundIndexWorkState
        switch settlement.outcome {
        case .completed: state = .completed
        case .failedConfirmed: state = .failedConfirmed
        case .outcomeUnknown: state = .outcomeUnknown
        case .cancelledBeforeDispatch: throw BackgroundIndexBudgetError.inactive
        }
        return try replacing(state: state, settlement: settlement, recovered: recovered)
    }
    func recovered(receiptID: String) throws -> Self {
        switch state {
        case .prepared: return try settled(BackgroundIndexWorkSettlement(receiptID: receiptID, outcome: .cancelledBeforeDispatch), recovered: true)
        case .armed, .submitted: return try settled(BackgroundIndexWorkSettlement(receiptID: receiptID, outcome: .outcomeUnknown), recovered: true)
        default: try validate(); return self
        }
    }
    private func replacing(state: BackgroundIndexWorkState, charged: BackgroundIndexResources? = nil,
                           held: BackgroundIndexResources? = nil, armedClock: BackgroundIndexClockSnapshot? = nil,
                           settlement: BackgroundIndexWorkSettlement? = nil, recovered: Bool? = nil) throws -> Self {
        let (revision, overflow) = self.revision.addingReportingOverflow(1); guard !overflow else { throw BackgroundIndexBudgetError.invalid }
        let result = Self(windowID: windowID, request: request, requestDigest: requestDigest, bindingDigest: bindingDigest, state: state,
            revision: revision, charged: charged ?? self.charged, held: held ?? self.held, createdClock: createdClock,
            armedClock: armedClock ?? self.armedClock, settlement: settlement ?? self.settlement, recovered: recovered ?? self.recovered)
        try result.validate(); return result
    }
    static func == (left: Self, right: Self) -> Bool {
        backgroundIndexIdentifierEqual(left.windowID, right.windowID) && left.request == right.request
            && backgroundIndexIdentifierEqual(left.requestDigest, right.requestDigest)
            && backgroundIndexIdentifierEqual(left.bindingDigest, right.bindingDigest) && left.state == right.state
            && left.revision == right.revision && left.charged == right.charged && left.held == right.held
            && left.createdClock == right.createdClock && left.armedClock == right.armedClock
            && left.settlement == right.settlement && left.recovered == right.recovered
    }
}

struct BackgroundIndexBudgetSnapshot: Codable, Equatable, Sendable, BackgroundIndexValidated {
    let version: String
    let window: BackgroundIndexWindow?
    let remaining: BackgroundIndexResources
    let rolloverEligible: Bool
    let pauseReason: BackgroundIndexPauseReason?
    init(window: BackgroundIndexWindow?, rolloverEligible: Bool = false, pauseReason: BackgroundIndexPauseReason? = nil) throws {
        self.version = "background-index-budget-snapshot-v1"; self.window = window
        self.remaining = try window?.remaining() ?? .zero; self.rolloverEligible = rolloverEligible
        self.pauseReason = window == nil ? .notStarted : pauseReason
        try validate()
    }
    func validate() throws {
        guard version == "background-index-budget-snapshot-v1" else { throw BackgroundIndexBudgetError.invalid }
        try window?.validate(); try remaining.validate()
        if let window { guard remaining == (try window.remaining()), pauseReason != .notStarted else { throw BackgroundIndexBudgetError.invalid } }
        else { guard remaining == .zero, !rolloverEligible, pauseReason == .notStarted else { throw BackgroundIndexBudgetError.invalid } }
    }
}
