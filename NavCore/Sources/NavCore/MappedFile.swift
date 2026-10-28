import Foundation

/// Файл, отображённый в память: не грузится целиком, телефон читает только нужные куски.
final class MappedFile {
    let ptr: UnsafeRawPointer
    let size: Int

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 { throw NavError.cannotOpen(path) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw NavError.cannotOpen(path) }
        let len = Int(st.st_size)
        if len < 16 { throw NavError.badFile(path) }
        guard let p = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0),
              p != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw NavError.cannotOpen(path)
        }
        self.ptr = UnsafeRawPointer(p)
        self.size = len
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: ptr), size)
    }

    @inline(__always) func u32(_ off: Int) -> UInt32 {
        return ptr.loadUnaligned(fromByteOffset: off, as: UInt32.self)
    }

    @inline(__always) func i32(_ off: Int) -> Int32 {
        return ptr.loadUnaligned(fromByteOffset: off, as: Int32.self)
    }

    @inline(__always) func f32(_ off: Int) -> Float {
        return ptr.loadUnaligned(fromByteOffset: off, as: Float.self)
    }

    @inline(__always) func u16(_ off: Int) -> UInt16 {
        return ptr.loadUnaligned(fromByteOffset: off, as: UInt16.self)
    }

    @inline(__always) func u8(_ off: Int) -> UInt8 {
        return ptr.loadUnaligned(fromByteOffset: off, as: UInt8.self)
    }

    func string(_ off: Int, _ len: Int) -> String {
        let buf = UnsafeBufferPointer(start: (ptr + off).assumingMemoryBound(to: UInt8.self), count: len)
        return String(decoding: buf, as: UTF8.self)
    }

    func hasMagic(_ s: String) -> Bool {
        let b = Array(s.utf8)
        for i in 0..<b.count where u8(i) != b[i] { return false }
        return true
    }
}

/// Помогает не обрабатывать один и тот же объект дважды при обходе ячеек.
public final class VisitMarker {
    var marks: [UInt32]
    var stamp: UInt32 = 0

    public init(count: Int) {
        marks = [UInt32](repeating: 0, count: max(count, 1))
    }

    public func begin() {
        stamp &+= 1
        if stamp == 0 {
            for i in 0..<marks.count { marks[i] = 0 }
            stamp = 1
        }
    }

    /// true — объект встретился впервые в этом обходе.
    @inline(__always) public func visit(_ i: Int) -> Bool {
        if marks[i] == stamp { return false }
        marks[i] = stamp
        return true
    }
}
