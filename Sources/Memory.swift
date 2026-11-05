// Kadr — возврат памяти системе после выгрузки окон.
import Foundation

enum MemoryRelief {
    private static var pending = false

    /// Через секунду-две после выгрузки вида: освобождённые страницы malloc отдаются системе
    /// (иначе они числятся за процессом до нехватки памяти).
    static func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            pending = false
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
