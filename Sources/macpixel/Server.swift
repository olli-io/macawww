import Foundation

/// Unix socket server on the main queue. One request line, one reply line per connection.
final class Server {
    private let fd: Int32
    private let path: String
    private let source: DispatchSourceRead

    init?(path: String, handler: @escaping ([String], @escaping (Reply) -> Void) -> Void) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withSockAddr(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard let line = sockReadLine(c) else { Darwin.close(c); return }
            let respond = { (r: Reply) in
                sockWrite(c, r.line)
                Darwin.close(c)
            }
            guard let args = decodeJSONLine(line) as? [String], !args.isEmpty else {
                return respond(.err("bad request"))
            }
            handler(args, respond)
        }
        source.resume()
    }

    func stop() {
        source.cancel()
        Darwin.close(fd)
        unlink(path)
    }
}
