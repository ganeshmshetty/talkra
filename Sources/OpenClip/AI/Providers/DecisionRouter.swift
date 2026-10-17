// DecisionRouter.swift
// OpenClip
//
// Which decision model decides what a spoken command means. `.provider` keeps routing on the active AI provider;
// the others are dedicated routers that return nil on any failure so the active provider takes over.
import Foundation
import Core

enum DecisionRouter: String, CaseIterable, Identifiable {
    case provider
    case jev
    case clef
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provider: return String(localized: "Same as AI provider")
        case .jev: return String(localized: "TypeSafe Jev")
        case .clef: return String(localized: "Cloudflare Clef")
        case .local: return String(localized: "Local decision server")
        }
    }

    static let cloudflareKeyAccount = "cloudflareRouterAPIKey"
    static let localKeyAccount = "localRouterAPIKey"

    static var current: DecisionRouter {
        DecisionRouter(rawValue: DefaultSettingsStore.shared.get(.aiRouter)) ?? .provider
    }

    @MainActor
    func decide(request: AgentRequest, actions: [ActionDescriptor], budget: RoutingBudget) async -> AgentDecision? {
        let store = DefaultSettingsStore.shared
        switch self {
        case .provider:
            return nil
        case .jev:
            return await JevRouting.decide(request: request, actions: actions, budget: budget)
        case .clef:
            let account = store.get(.aiRouterCloudflareAccount).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SecretStore.get(account: Self.cloudflareKeyAccount) ?? ""
            let model = store.get(.aiRouterCloudflareModel)
            guard !account.isEmpty, !key.isEmpty,
                  let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/\(model)") else { return nil }
            return await JevRouting.decide(request: request, actions: actions, budget: budget, endpoint: url, apiKey: key, model: model)
        case .local:
            guard let url = URL(string: store.get(.aiRouterLocalURL).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return await JevRouting.decide(
                request: request, actions: actions, budget: .local, endpoint: url,
                apiKey: SecretStore.get(account: Self.localKeyAccount), model: store.get(.aiRouterLocalModel)
            )
        }
    }
}
