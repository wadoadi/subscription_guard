import Flutter
import StoreKit

public class SubscriptionGuardPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "subscription_guard/storekit",
      binaryMessenger: registrar.messenger())
    let instance = SubscriptionGuardPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "latestTransaction",
          let args = call.arguments as? [String: Any],
          let pid = args["productId"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    if #available(iOS 15.0, *) {
      Task { @MainActor in
        guard let latest = await Transaction.latest(for: pid) else {
          result(["state": "none"])
          return
        }
        switch latest {
        case .unverified:
          result(["state": "unverified"])
        case .verified(let t):
          if t.revocationDate != nil {
            result(["state": "revoked"])
            return
          }
          let ms = Int64((t.expirationDate ?? .distantPast).timeIntervalSince1970 * 1000)
          result(["state": "verified", "expiresAtMs": ms])
        }
      }
    } else {
      result(["state": "unsupported_ios"])
    }
  }
}
