//
//  LockedDataCallback.swift
//  SwiftTerm
//
//  Replaceable byte-slice callback for the process data tap.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// Stores a replaceable `(ArraySlice<UInt8>) -> Void` callback without passing
/// the function value through a generic container.
///
/// Reading a closure back out of `Locked<(@Sendable (ArraySlice<UInt8>) -> Void)?>`
/// re-abstracts it each time, wrapping it in one more thunk pair per read. The
/// parse thread reads the tap once per output batch, so the call depth grew with
/// every batch until the thread overflowed its stack. The closure here lives in
/// a final class box and is only ever handed around as that class reference, so
/// each call has constant depth.
final class LockedDataCallback: @unchecked Sendable {
    private final class Box: Sendable {
        let body: @Sendable (ArraySlice<UInt8>) -> Void

        init(_ body: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
            self.body = body
        }
    }

    private let lock = NSLock()
    private var box: Box?

    init() {}

    func replace(with body: (@Sendable (ArraySlice<UInt8>) -> Void)?) {
        let next = body.map(Box.init)
        lock.lock()
        box = next
        lock.unlock()
    }

    /// Whether a callback is installed (lets callers skip building the slice).
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return box != nil
    }

    func call(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        let current = box
        lock.unlock()
        current?.body(bytes)
    }
}

#endif // !SWIFTTERM_EMBEDDED
