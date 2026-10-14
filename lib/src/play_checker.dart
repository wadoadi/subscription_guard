import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import '../subscription_guard.dart';

/// Android: checks Play Billing for an active purchase of [productId].
/// Expiry is not visible on-device, so a valid result is trusted for [recheckInterval].
class PlayEntitlementChecker implements EntitlementChecker {
  final String productId;
  final Duration recheckInterval;

  PlayEntitlementChecker(this.productId,
      {this.recheckInterval = const Duration(days: 7)});

  @override
  Future<CheckOutcome> check() async {
    final android = InAppPurchase.instance
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final resp = await android.queryPastPurchases();
    if (resp.error != null) return CheckUnknown(resp.error!.message);

    final active = resp.pastPurchases.any((d) =>
        d.productID == productId &&
        (d.status == PurchaseStatus.purchased ||
            d.status == PurchaseStatus.restored));

    return active
        ? CheckValid(DateTime.now().add(recheckInterval))
        : const CheckExpired();
  }
}
