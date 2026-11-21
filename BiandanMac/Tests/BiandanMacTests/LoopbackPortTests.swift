import Darwin
import Network
import XCTest
@testable import BiandanMac

final class LoopbackPortTests: XCTestCase {
    func testClassifiesListenerErrors() {
        XCTAssertEqual(AuthError.listenerFailure(NWError.posix(.EADDRINUSE)), .portInUse)
        XCTAssertEqual(AuthError.listenerFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))), .portInUse)
        if case .listenerFailed = AuthError.listenerFailure(NWError.posix(.EACCES)) {} else {
            XCTFail("EACCES 应归为其他监听错误")
        }
        XCTAssertEqual(AuthError.listenerFailure(nil), .portUnavailable)
        XCTAssertTrue(AuthError.portInUse.errorDescription?.contains("lsof -nP -iTCP:42681") == true)
    }

    /// 真实占用一个回环端口：NWListener（allowLocalEndpointReuse）在这种情况下报的是 EINVAL，
    /// 带上端口探测后仍应识别为「被占用」。
    func testDetectsOccupiedPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertTrue(LoopbackPort.isInUse(port), "有程序监听时应判为占用")

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let failed = expectation(description: "监听失败")
        var result: AuthError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                if result == nil {
                    result = AuthError.listenerFailure(error, port: port)
                    failed.fulfill()
                }
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "loopback-port-test"))
        wait(for: [failed], timeout: 5)
        listener.cancel()
        XCTAssertEqual(result, .portInUse)
    }
}
