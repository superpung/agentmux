import Foundation

/// FileHandle creates autoreleased NSData objects even when its Swift result
/// is Data. A long-lived reader must drain those temporary references per read,
/// while the returned value keeps ownership until its consumer finishes.
enum PipeReader {
    static func readAvailable(from handle: FileHandle) -> Data {
        autoreleasepool { handle.availableData }
    }
}
