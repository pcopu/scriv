import Foundation

/// Public UI state only. Codes, PKCE verifiers and session tokens never enter this
/// value, user defaults, project packages or diagnostic logs.
public struct EmailSignInFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, requesting, awaitingCode, verifying }
    public private(set) var phase: Phase = .idle
    public private(set) var email = ""
    public private(set) var challengeID: String?
    public private(set) var expiresAt: Date?
    public private(set) var resendAt: Date?
    public private(set) var errorMessage: String?
    public private(set) var operationID: UUID?
    public init() {}

    public var isBusy: Bool { phase == .requesting || phase == .verifying }
    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? true }
    public func resendSeconds(at now: Date) -> Int { seconds(until:resendAt,now:now) }
    public func expirySeconds(at now: Date) -> Int { seconds(until:expiresAt,now:now) }
    public func canResend(at now: Date) -> Bool { !isBusy && !email.isEmpty && resendSeconds(at:now) == 0 }
    private func seconds(until date: Date?, now: Date) -> Int {
        guard let date else { return 0 }
        return Int(min(900,max(0,ceil(date.timeIntervalSince(now)))))
    }

    public static func normalizedEmail(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let parts = email.split(separator:"@",omittingEmptySubsequences:false)
        guard email.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
              parts[0].utf8.allSatisfy({ asciiLetterOrDigit($0) || Array(".!#$%&'*+/=?^_`{|}~-".utf8).contains($0) }),
              !parts[1].isEmpty, parts[1].contains("."),
              parts[1].split(separator:".",omittingEmptySubsequences:false).allSatisfy({ label in
                  guard let first = label.utf8.first, let last = label.utf8.last else { return false }
                  return label.utf8.count <= 63 && asciiLetterOrDigit(first) && asciiLetterOrDigit(last) && label.utf8.allSatisfy({ asciiLetterOrDigit($0) || $0 == 45 })
              }) else {
            throw ScrivError.invalid("Enter a valid email address.")
        }
        return email
    }
    private static func asciiLetterOrDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...122).contains(byte) }
    public static func normalizedCode(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ScrivError.invalid("Enter the six-digit code from your email.") }
        return code
    }

    @discardableResult
    public mutating func beginRequest(email rawEmail: String, now: Date = Date()) throws -> UUID {
        guard !isBusy else { throw ScrivError.conflict("Wait for the current sign-in request.") }
        let normalized = try Self.normalizedEmail(rawEmail)
        guard email.isEmpty || email == normalized else { throw ScrivError.conflict("Cancel this sign-in before using another email address.") }
        guard resendSeconds(at:now) == 0 else { throw ScrivError.conflict("Wait a moment before requesting another code.") }
        let operation = UUID()
        email = normalized; phase = .requesting; operationID = operation; challengeID = nil; expiresAt = nil
        // A lost response may still have sent email. Do not immediately duplicate it.
        resendAt = now.addingTimeInterval(60); errorMessage = nil
        return operation
    }

    @discardableResult
    public mutating func receivedChallenge(id: String, expiresAtMilliseconds: Int64, resendAtMilliseconds: Int64, operation: UUID, now: Date = Date()) throws -> Bool {
        guard phase == .requesting, operationID == operation else { return false }
        let expiry = Date(timeIntervalSince1970:Double(expiresAtMilliseconds)/1000)
        let resend = Date(timeIntervalSince1970:Double(resendAtMilliseconds)/1000)
        guard id.utf8.count == 43,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              expiry > now, expiry.timeIntervalSince(now) <= 900,
              resend <= expiry, resend.timeIntervalSince(now) <= 120 else {
            throw ScrivError.invalid("The server returned an invalid sign-in challenge. Check your Mac's date and time, then request another code.")
        }
        challengeID = id; expiresAt = expiry; resendAt = max(now,resend); phase = .awaitingCode; operationID = nil; errorMessage = nil
        return true
    }

    @discardableResult
    public mutating func beginVerification(code: String, now: Date = Date()) throws -> UUID {
        guard phase == .awaitingCode, challengeID != nil else { throw ScrivError.conflict("Request an email code first.") }
        guard !isExpired(at:now) else { throw ScrivError.invalid("This code has expired. Request a new code below.") }
        _ = try Self.normalizedCode(code)
        let operation = UUID(); phase = .verifying; operationID = operation; errorMessage = nil
        return operation
    }

    public mutating func fail(operation: UUID, message: String, retryAfter: TimeInterval? = nil, now: Date = Date()) {
        guard operationID == operation else { return }
        phase = challengeID == nil ? .idle : .awaitingCode; operationID = nil
        errorMessage = String(message.prefix(500))
        if let retryAfter { resendAt = max(resendAt ?? now,now.addingTimeInterval(min(120,max(0,retryAfter)))) }
    }
    public mutating func showValidationError(_ message: String) { if !isBusy { errorMessage = String(message.prefix(500)) } }
    public mutating func cancel() { self = Self() }
}
