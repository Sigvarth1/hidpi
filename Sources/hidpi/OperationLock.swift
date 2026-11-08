import Foundation
import Darwin

/// Prevent CLI previews, menu actions, and automatic restoration from racing each other.
final class OperationLock {
    private let descriptor: Int32
    init() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local.hidpi.display-operation.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIError("cannot open display operation lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CLIError("another HiDPI process is changing displays; try again when it finishes")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
