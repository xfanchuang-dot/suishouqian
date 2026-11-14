import Foundation

/// 购买入口的单一事实来源。改销售渠道只改这里——
/// App 按钮、README、站点购买页都以它为准，避免三处各写一个链接。
enum PurchaseLinks {
    /// Pro 结算页（xios.uk）：支付宝转账 + 人工发许可证
    static let proCheckout = URL(string: "https://xios.uk/suishouqian/buy/")!
    /// 售后与发货邮箱（转账凭证发这里）
    static let supportEmail = "hello@xios.uk"
}
