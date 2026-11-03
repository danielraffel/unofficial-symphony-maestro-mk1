// Read the ThunderBridge dext's timing/register health snapshot.
//
// This is intentionally a read-only diagnostic. It does not change the
// sample rate, host buffer, routing, or hardware state.

import Foundation
import IOKit

let userClientType: UInt32 = 0x53594D43 // 'SYMC'
let selectorReadTimingHealth: UInt32 = 3

guard let matching = IOServiceNameMatching("SymphonyThunderbridge") else {
    fputs("unable to create IOService match\n", stderr)
    exit(1)
}
let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
guard service != IO_OBJECT_NULL else {
    fputs("ThunderBridge dext service not found\n", stderr)
    exit(1)
}
defer { IOObjectRelease(service) }

var connection: io_connect_t = IO_OBJECT_NULL
guard IOServiceOpen(service, mach_task_self_, userClientType, &connection) == KERN_SUCCESS else {
    fputs("unable to open ThunderBridge user client\n", stderr)
    exit(1)
}
defer { IOServiceClose(connection) }

var words = [UInt32](repeating: 0, count: 12)
var outputSize = words.count * MemoryLayout<UInt32>.size
let result = words.withUnsafeMutableBytes { bytes in
    IOConnectCallStructMethod(connection, selectorReadTimingHealth,
                              nil, 0, bytes.baseAddress, &outputSize)
}
guard result == KERN_SUCCESS, words[0] == 0 else {
    fputs(String(format: "timing health failed: 0x%08x\n", result), stderr)
    exit(1)
}

let frame = words[5]
let expected = words[6]
print("ThunderBridge timing health")
print(String(format: "rate=%u Hz frame=%u expected=%u clkCtrl=0x%08x",
             words[7], frame, expected, words[1]))
print(String(format: "latency in/out=%u/%u safety in/out=%u/%u",
             words[8], words[9], words[10], words[11]))
print(String(format: "intStatus=0x%08x xlinkStatus=0x%08x gcsr=0x%08x",
             words[2], words[3], words[4]))
