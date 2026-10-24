import CPrivate
import CoreGraphics
import Foundation
import IOKit

/// DDC/CI is the "remote control" channel that runs over the monitor cable.
/// It lets us change the monitor's real (hardware) brightness, contrast and volume.
enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case inputSource = 0x60
}

/// One external monitor reachable over DDC on Apple Silicon.
final class DDCService {
    let service: AnyObject
    private let chipAddress: UInt32 = 0x37
    private let dataAddress: UInt32 = 0x51
    private let lock = NSLock()

    init(service: AnyObject) {
        self.service = service
    }

    @discardableResult
    func write(_ code: VCP, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(start: UInt8(chipAddress << 1) ^ UInt8(dataAddress), packet[0 ..< 5])
        lock.lock(); defer { lock.unlock() }
        var ok = false
        // Monitors occasionally drop packets, so send twice like MonitorControl does.
        for _ in 0 ..< 2 {
            usleep(10000)
            let result = packet.withUnsafeMutableBytes {
                IOAVServiceWriteI2C(service, chipAddress, dataAddress, $0.baseAddress, UInt32($0.count))
            }
            ok = ok || result == kIOReturnSuccess
        }
        return ok
    }

    /// Returns (current, max) or nil if the monitor didn't answer.
    func read(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, code.rawValue, 0]
        request[3] = checksum(start: UInt8(chipAddress << 1) ^ UInt8(dataAddress), request[0 ..< 3])
        lock.lock(); defer { lock.unlock() }
        for _ in 0 ..< 4 {
            var reply = [UInt8](repeating: 0, count: 12)
            usleep(10000)
            let w = request.withUnsafeMutableBytes {
                IOAVServiceWriteI2C(service, chipAddress, dataAddress, $0.baseAddress, UInt32($0.count))
            }
            guard w == kIOReturnSuccess else { continue }
            usleep(50000)
            let r = reply.withUnsafeMutableBytes {
                IOAVServiceReadI2C(service, chipAddress, 0, $0.baseAddress, UInt32($0.count))
            }
            guard r == kIOReturnSuccess else { continue }
            // reply[2] == 0x02 is "VCP feature reply", reply[3] == 0 means no error.
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            if max > 0 { return (current, max) }
        }
        return nil
    }

    private func checksum(start: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(start) { $0 ^ $1 }
    }
}

/// Information macOS keeps about each external screen in the I/O registry.
struct RegistryDisplay {
    var productName: String?
    var vendorID: UInt32?
    var productID: UInt32?
    var serial: UInt32?
    var service: AnyObject
}

enum DDCDiscovery {
    /// Walks the I/O registry. On Apple Silicon each screen shows up as a
    /// framebuffer entry ("AppleCLCD2" / "IOMobileFramebufferShim") followed by
    /// a "DCPAVServiceProxy" that we can send DDC commands through.
    static func externalServices() -> [RegistryDisplay] {
        var found: [RegistryDisplay] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return found
        }
        defer { IOObjectRelease(iterator) }

        var pendingAttributes: [String: Any]?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)

            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                    pendingAttributes = attrs["ProductAttributes"] as? [String: Any]
                } else {
                    pendingAttributes = nil
                }
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                guard location == "External" else { pendingAttributes = nil; continue }
                guard let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                let attrs = pendingAttributes ?? [:]
                found.append(RegistryDisplay(
                    productName: attrs["ProductName"] as? String,
                    vendorID: (attrs["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? (attrs["ManufacturerID"] as? NSNumber)?.uint32Value,
                    productID: (attrs["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (attrs["SerialNumber"] as? NSNumber)?.uint32Value,
                    service: av
                ))
                pendingAttributes = nil
            }
        }
        return found
    }

    /// Pairs each macOS screen (CGDirectDisplayID) with its DDC service by
    /// comparing vendor, model and serial numbers. Falls back to order.
    static func match(displays: [CGDirectDisplayID], services: [RegistryDisplay]) -> [CGDirectDisplayID: RegistryDisplay] {
        var result: [CGDirectDisplayID: RegistryDisplay] = [:]
        var remaining = services
        for id in displays {
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            var bestIndex: Int?
            var bestScore = 0
            for (i, s) in remaining.enumerated() {
                var score = 0
                if s.vendorID == vendor { score += 1 }
                if s.productID == model { score += 2 }
                if let sSerial = s.serial, sSerial != 0, sSerial == serial { score += 4 }
                if score > bestScore { bestScore = score; bestIndex = i }
            }
            if let i = bestIndex {
                result[id] = remaining.remove(at: i)
            }
        }
        for id in displays where result[id] == nil {
            if !remaining.isEmpty { result[id] = remaining.removeFirst() }
        }
        return result
    }
}
