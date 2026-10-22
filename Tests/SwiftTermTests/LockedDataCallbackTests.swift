import Dispatch
import Foundation
import Testing
@testable import SwiftTerm

/// Guards the process data tap store. Storing the closure in a generic
/// `Locked<(@Sendable (ArraySlice<UInt8>) -> Void)?>` and reading it back per
/// chunk wrapped it in one more reabstraction thunk per read, so the call
/// depth grew with every output batch until the parse thread overflowed.
struct LockedDataCallbackTests {
    private static func stackAddress() -> UInt {
        var marker = 0
        return withUnsafePointer(to: &marker) { UInt(bitPattern: $0) }
    }

    @Test func repeatedCallsDoNotGrowTheCallbackStack() {
        let addresses = Locked<[UInt]>([])
        let callback = LockedDataCallback()
        callback.replace { _ in
            let address = LockedDataCallbackTests.stackAddress()
            addresses.withLock { $0.append(address) }
        }

        let bytes: [UInt8] = [1, 2, 3]
        for _ in 0..<10_000 {
            callback.call(bytes[...])
        }

        let samples = addresses.withLock { $0 }
        let first = samples.first ?? 0
        let last = samples.last ?? 0
        let stackGrowth = first > last ? first - last : last - first

        #expect(samples.count == 10_000)
        #expect(stackGrowth < 4_096, "data callback stack grew by \(stackGrowth) bytes")
    }

    @Test func manyCallsFitOnASmallStack() {
        let callback = LockedDataCallback()
        let total = Locked(0)
        callback.replace { slice in total.withLock { $0 += slice.count } }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let bytes = [UInt8](repeating: 7, count: 64)
            for _ in 0..<100_000 { callback.call(bytes[...]) }
            done.signal()
        }
        thread.stackSize = 64 * 1024
        thread.start()
        done.wait()
        #expect(total.withLock { $0 } == 6_400_000)
    }

    @Test func callsReachTheLatestHandlerAndNilDisables() {
        let callback = LockedDataCallback()
        #expect(!callback.isSet)
        callback.call([9][...])
        let seen = Locked<[Int]>([])
        callback.replace { slice in seen.withLock { $0.append(slice.count) } }
        #expect(callback.isSet)
        callback.call([1, 2][...])
        callback.replace { slice in seen.withLock { $0.append(slice.count * 10) } }
        callback.call([1, 2, 3][...])
        callback.replace(with: nil)
        callback.call([1][...])
        #expect(seen.withLock { $0 } == [2, 30])
    }

    @Test func concurrentCallsAndReplacementsRemainSafe() {
        let callback = LockedDataCallback()
        let calls = Locked(0)
        let body: @Sendable (ArraySlice<UInt8>) -> Void = { _ in calls.withLock { $0 += 1 } }
        let bytes: [UInt8] = [0]
        DispatchQueue.concurrentPerform(iterations: 10_000) { iteration in
            if iteration.isMultiple(of: 8) {
                callback.replace(with: iteration.isMultiple(of: 16) ? nil : body)
            } else {
                callback.call(bytes[...])
            }
        }
        callback.replace(with: body)
        callback.call(bytes[...])
        #expect(calls.withLock { $0 } > 0)
    }
}
