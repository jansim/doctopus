import Foundation
import Darwin

/// Keeps a library to one running Doctopus at a time. Two writers on one
/// index — a second Mac on a shared or synced folder, or a second copy of the
/// app — interleave their writes and can corrupt it.
///
/// Two locks in one file, because neither covers both cases: `flock` is exact
/// between processes on one Mac but does not travel through Dropbox or iCloud,
/// and the owner record written into the file does travel, but can only say
/// when it was last renewed. A record from another Mac counts until it has
/// gone unrenewed for `staleAfter`, which is what lets a Mac that crashed or
/// lost the network give the library up without anyone deleting anything.
final class LibraryLock: @unchecked Sendable {
    struct Owner: Codable, Sendable, Equatable {
        var machine: String
        var name: String
        var pid: Int32
        var heartbeat: Date
    }

    enum Refusal: Swift.Error, CustomStringConvertible {
        case inUse(Owner?)
        case unavailable(String)

        var description: String {
            switch self {
            case .inUse(let owner?) where owner.machine != LibraryLock.thisMachine:
                return "This library is open in Doctopus on “\(owner.name)”. Close it there first — "
                    + "two Macs writing one index can corrupt it. If that Mac is off or asleep, the library "
                    + "opens here once it has gone \(Int(LibraryLock.staleAfter / 60)) minutes without checking in."
            case .inUse:
                return "This library is already open in another copy of Doctopus on this Mac. Close it there first."
            case .unavailable(let reason):
                return "This library could not be locked for use (\(reason)), so it was not opened."
            }
        }
    }

    static let filename = "lock"
    static let renewEvery: TimeInterval = 60
    static let staleAfter: TimeInterval = 5 * 60

    /// Stable for this Mac, unlike its name.
    static let thisMachine: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return ProcessInfo.processInfo.hostName }
        return NSUUID(uuidBytes: bytes).uuidString
    }()

    static let thisMachineName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    let url: URL
    private let guardLock = NSLock()
    private var fd: Int32
    private var timer: DispatchSourceTimer?

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// Takes the lock, or says who has it. `now` is for the checks.
    static func acquire(in container: URL, now: Date = Date()) throws -> LibraryLock {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let url = container.appendingPathComponent(filename)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Refusal.unavailable(String(cString: strerror(errno))) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            // Some network volumes do not do flock at all; the owner record
            // is then all there is to go on.
            if code != ENOTSUP && code != EOPNOTSUPP {
                let owner = read(fd)
                close(fd)
                throw code == EWOULDBLOCK ? Refusal.inUse(owner) : Refusal.unavailable(String(cString: strerror(code)))
            }
        }
        // flock is only as good as the Mac it was taken on: another one's
        // record counts until it goes stale.
        if let owner = read(fd), owner.machine != thisMachine,
           now.timeIntervalSince(owner.heartbeat) < staleAfter {
            close(fd)
            throw Refusal.inUse(owner)
        }

        let lock = LibraryLock(url: url, fd: fd)
        lock.renew(now: now)
        lock.startRenewing()
        return lock
    }

    /// The owner record in a library's lock file, if there is one.
    static func owner(in container: URL) -> Owner? {
        let fd = open(container.appendingPathComponent(filename).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return read(fd)
    }

    /// Identifies the lock file itself, so the same library reached by two
    /// paths is recognised as one.
    static func identity(in container: URL) -> String? {
        var info = stat()
        guard stat(container.appendingPathComponent(filename).path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    var identity: String? {
        guardLock.withLock {
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0 else { return nil }
            return "\(info.st_dev):\(info.st_ino)"
        }
    }

    /// Clears the owner record, so another Mac need not wait out `staleAfter`,
    /// and lets go. Safe to call more than once.
    func release() {
        guardLock.withLock {
            timer?.cancel()
            timer = nil
            guard fd >= 0 else { return }
            ftruncate(fd, 0)
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    private func renew(now: Date = Date()) {
        guardLock.withLock {
            guard fd >= 0 else { return }
            let owner = Owner(machine: Self.thisMachine, name: Self.thisMachineName,
                              pid: getpid(), heartbeat: now)
            guard let data = try? JSONEncoder().encode(owner) else { return }
            ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            fsync(fd)
        }
    }

    private func startRenewing() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.renewEvery, repeating: Self.renewEvery, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.renew() }
        guardLock.withLock { self.timer = timer }
        timer.resume()
    }

    private static func read(_ fd: Int32) -> Owner? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var offset: off_t = 0
        while true {
            let n = pread(fd, &buffer, buffer.count, offset)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            offset += off_t(n)
        }
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }
}
