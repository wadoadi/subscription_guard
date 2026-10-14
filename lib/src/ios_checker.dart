import 'package:flutter/services.dart';
import '../subscription_guard.dart';

/// iOS: asks the native side (StoreKit 2) for the latest transaction of [productId].
class IosEntitlementChecker implements EntitlementChecker {
  static const _channel = MethodChannel('subscription_guard/storekit');
  final String productId;

  IosEntitlementChecker(this.productId);

  @override
  Future<CheckOutcome> check() async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
          'latestTransaction', {'productId': productId});
      final state = r?['state'] as String? ?? 'none';
      switch (state) {
        case 'verified':
          final expires =
              DateTime.fromMillisecondsSinceEpoch(r!['expiresAtMs'] as int);
          return expires.isAfter(DateTime.now())
              ? CheckValid(expires)
              : CheckExpired(expires);
        case 'revoked':
        case 'none':
          return const CheckExpired();
        default:
          return CheckUnknown(state);
      }
    } on PlatformException catch (e) {
      return CheckUnknown(e.message ?? 'platform error');
    }
  }
}
