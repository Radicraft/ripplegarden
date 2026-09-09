import Foundation
import StoreKit

/// The subscription that pays for seasons after the first four. The launch
/// content is free; this only ever gates what comes later, plus cosmetics.
/// Product IDs must match App Store Connect.
@MainActor
final class Store: ObservableObject {

    static let shared = Store()

    /// Apple's standard licence for App Store apps, and the privacy policy the
    /// owner publishes. Both are shown on the paywall, as the guidelines ask.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static var privacyURL: URL? = URL(string: "https://radicraft.co.uk/ripple/privacy")

    static let monthlyID = "com.radicraft.ripple.seasons.monthly"
    static let annualID = "com.radicraft.ripple.seasons.annual"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var lastError: String?

    private var updates: Task<Void, Never>?

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result {
                    await t.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
        Task { await load() }
    }

    func load() async {
        do {
            products = try await Product.products(for: [Store.monthlyID, Store.annualID])
                .sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result, case .verified(let t) = verification {
                await t.finish()
            }
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The Settings button. StoreKit 2 restores by syncing with the App Store.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Store.monthlyID || t.productID == Store.annualID,
               t.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
    }
}
