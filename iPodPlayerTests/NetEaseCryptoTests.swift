import XCTest
@testable import iPodPlayer

final class NetEaseCryptoTests: XCTestCase {
    func testWeapiMatchesGoldenVector() throws {
        let payloadJSON = "{\"s\":\"周杰伦\",\"type\":1,\"offset\":0,\"limit\":3,\"total\":true,\"csrf_token\":\"\"}"
        let output = try XCTUnwrap(
            WeapiCrypto.encrypt(payloadJSON: payloadJSON, secretKey: "0123456789abcdef")
        )

        XCTAssertEqual(
            output.params,
            "DxVOVqI5w4fJyAFk0z/oxPjcmCSYIfo4ejP84p27Kbzrkik8U1CMibol1Vlh/YU0619oqRQnoz+2C1HjVfeDCfuD3JPJvOi774UQaEY67Oq5rT/Le/J5qV6YY1T8kSqjOfmf7bx1puF1GjmQCFcsNA=="
        )
        XCTAssertEqual(
            output.encSecKey,
            "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52"
        )
        XCTAssertEqual(output.encSecKey.count, 256)
    }

    func testWeapiRSAPlaintextPadding() throws {
        let plain = try XCTUnwrap(WeapiCrypto.rsaPlaintext(reversedKey: "fedcba9876543210"))
        XCTAssertEqual(plain.count, 128)
        XCTAssertEqual(
            plain.hexString,
            "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000066656463626139383736353433323130"
        )
    }

    func testEapiMatchesGoldenVector() throws {
        let payloadJSON = "{\"ids\":\"[186016]\",\"level\":\"exhigh\",\"encodeType\":\"flac\"}"
        let apiPath = "/api/song/enhance/player/url/v1"

        XCTAssertEqual(
            EapiCrypto.digest(apiPath: apiPath, payloadJSON: payloadJSON),
            "e3f09a431d9c376bb6e2a13b99828c77"
        )
        XCTAssertEqual(
            EapiCrypto.encrypt(apiPath: apiPath, payloadJSON: payloadJSON),
            "FA90B329E9614F79E79598F37DC2EDB487F00D1BC4C9B24CD57E6C318B9073569338432CD7D98D1A3626E997A2C531218543BC970F66310273D4660DAF94B6719C2FC721B3DDEEEAF7AD2C922A208A3D3AF14D08BA832D5BE8390E493266BD176D25E1071E51EEF3361F325C78CC9F573370C2937D7CF5ED6A2B5301613F7C427CD4D717C3F59AAE88BC0B92891A29996AA3B102FBE7296AB0DB9EA5C46AD12B"
        )
    }
}
