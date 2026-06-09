import Darwin
import Foundation

enum MemoryPressureRelief {
    static func releaseAfterCurrentEvent() {
        DispatchQueue.main.async {
            releaseNow()
        }
    }

    static func releaseNow() {
        autoreleasepool {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    static func currentFootprintMegabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
