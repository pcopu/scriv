import XCTest
@testable import ScrivCore

final class DigestTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(ScrivDigest.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ScrivDigest.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ScrivDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
    func testPlatformAndPortableImplementationsAgree() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 65_537] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            XCTAssertEqual(ScrivDigest.bytes(data), ScrivDigest.portableBytes(data), "length \(length)")
        }
    }
}
