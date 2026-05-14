import Foundation

struct ReceiptJSON: Codable {
    let date: String       // yyyy/MM/dd
    let weekday: String?
    let necessity: String
    let category: String
    let total: Int

    enum CodingKeys: String, CodingKey {
        case total, date, weekday
        case necessity = "necessity"
        case category = "category"
    }
}
