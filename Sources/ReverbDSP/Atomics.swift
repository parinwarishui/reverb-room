//
//  Atomics.swift
//  Small wrappers over RRAtomics, so Swift code can share values with the
//  real-time thread without locks.
//

import RRAtomics

public final class AtomicFloat {
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    public init(_ value: Float) { storage.initialize(to: value) }
    deinit { storage.deallocate() }

    public var value: Float {
        get { rr_load_float(storage) }
        set { rr_store_float(storage, newValue) }
    }
}

public final class AtomicCounter {
    private let storage = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    public init() { storage.initialize(to: 0) }
    deinit { storage.deallocate() }

    public var value: UInt32 { rr_load_u32(storage) }
    public func increment() { rr_add_u32(storage, 1) }
}

/// One pointer that two threads hand back and forth with an atomic exchange.
final class AtomicPointerSlot {
    private let storage = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)

    init() { storage.initialize(to: nil) }
    deinit { storage.deallocate() }

    var isEmpty: Bool { rr_load_ptr(storage) == nil }

    /// Stores `value` and returns what was there before.
    func exchange(_ value: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        rr_exchange_ptr(storage, value)
    }
}
