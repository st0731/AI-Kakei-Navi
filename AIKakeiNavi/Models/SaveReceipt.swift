import Foundation
import SwiftData

@Model
class SavedReceipt {
    var isIncome: Bool
    var memo: String
    var receiptDate: Date
    var weekday: String
    var necessity: String
    var category: String
    var total: Int
    var paymentMethod: String
    var createdAt: Date

    init(
        isIncome: Bool = false,
        memo: String = "",
        receiptDate: Date = Date(),
        weekday: String = "",
        necessity: String = "",
        category: String = "",
        total: Int = 0,
        paymentMethod: String = "未設定"
    ) {
        self.isIncome = isIncome
        self.memo = memo
        self.receiptDate = receiptDate
        self.weekday = weekday
        self.necessity = necessity
        self.category = category
        self.total = total
        self.paymentMethod = paymentMethod
        self.createdAt = Date()
    }
}
