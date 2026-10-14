import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

export 'src/play_checker.dart';
export 'src/ios_checker.dart';

enum GuardDecision { allowed, allowedWithWarning, grace, revoked }

class GuardResult {
  final GuardDecision decision;
  final String? message;
  final DateTime? accessEndsAt;
  const GuardResult(this.decision, {this.message, this.accessEndsAt});
  bool get hasAccess => decision != GuardDecision.revoked;
}

sealed class CheckOutcome {
  const CheckOutcome();
}

/// Store reports an active subscription.
class CheckValid extends CheckOutcome {
  final DateTime expiresAt;
  const CheckValid(this.expiresAt);
}

/// Store positively reports the subscription has lapsed.
class CheckExpired extends CheckOutcome {
  final DateTime? expiredAt;
  const CheckExpired([this.expiredAt]);
}

/// No usable answer: offline, timeout, store error, unverified receipt.
class CheckUnknown extends CheckOutcome {
  final String reason;
  const CheckUnknown(this.reason);
}

abstract class EntitlementChecker {
  Future<CheckOutcome> check();
}

class GuardConfig {
  /// How long a valid result is trusted before re-checking.
  final Duration recheckInterval;

  /// Time between first detected expiry and access ending.
  final Duration expiredGrace;

  /// Failed runs allowed before revoking.
  final int maxFailedRuns;

  /// Maximum time since the first failure before revoking.
  final Duration maxFailureWindow;

  final Duration checkTimeout;

  const GuardConfig({
    this.recheckInterval = const Duration(days: 7),
    this.expiredGrace = const Duration(hours: 48),
    this.maxFailedRuns = 4,
    this.maxFailureWindow = const Duration(days: 7),
    this.checkTimeout = const Duration(seconds: 15),
  });
}

class SubscriptionGuard {
  final String appId;
  final EntitlementChecker checker;
  final GuardConfig config;
  final DateTime Function() clock;

  SubscriptionGuard({
    required this.appId,
    required this.checker,
    this.config = const GuardConfig(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  String _k(String s) => 'subguard.$appId.$s';

  DateTime? _date(SharedPreferences p, String k) {
    final v = p.getInt(_k(k));
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> _setDate(SharedPreferences p, String k, DateTime? v) =>
      v == null ? p.remove(_k(k)) : p.setInt(_k(k), v.millisecondsSinceEpoch);

  Future<void> _clearFailures(SharedPreferences p) async {
    await p.remove(_k('failCount'));
    await _setDate(p, 'firstFailure', null);
  }

  Future<CheckOutcome> _safeCheck() async {
    try {
      return await checker.check().timeout(
            config.checkTimeout,
            onTimeout: () => const CheckUnknown('timeout'),
          );
    } catch (e) {
      return CheckUnknown(e.toString());
    }
  }

  /// Call once per app launch.
  Future<GuardResult> evaluate() async {
    final p = await SharedPreferences.getInstance();
    final now = clock();

    final lastCheck = _date(p, 'lastCheck');
    final validUntil = _date(p, 'validUntil');
    final expiredSince = _date(p, 'expiredSince');
    final failCount = p.getInt(_k('failCount')) ?? 0;
    final firstFailure = _date(p, 'firstFailure');

    // Guard against clock rollback: a lastCheck in the future is treated as untrusted.
    if (lastCheck != null && lastCheck.isAfter(now)) {
      return const GuardResult(GuardDecision.revoked,
          message: 'Device clock looks incorrect. Please check the date and time.');
    }

    // 1. Known-good token: skip the store until the recheck window closes.
    if (lastCheck != null &&
        validUntil != null &&
        expiredSince == null &&
        failCount == 0) {
      final recheckAt = lastCheck.add(config.recheckInterval);
      final skipUntil = recheckAt.isBefore(validUntil) ? recheckAt : validUntil;
      if (now.isBefore(skipUntil)) {
        return const GuardResult(GuardDecision.allowed);
      }
    }

    // 2. Ask the store.
    final outcome = await _safeCheck();

    switch (outcome) {
      case CheckValid(:final expiresAt):
        await _setDate(p, 'lastCheck', now);
        await _setDate(p, 'validUntil', expiresAt);
        await _setDate(p, 'expiredSince', null);
        await _clearFailures(p);
        return const GuardResult(GuardDecision.allowed);

      case CheckExpired(:final expiredAt):
        final since = expiredSince ?? expiredAt ?? now;
        await _setDate(p, 'lastCheck', now);
        await _setDate(p, 'expiredSince', since);
        await _clearFailures(p);
        return _lapsed(since, now);

      case CheckUnknown(:final reason):
        final fc = failCount + 1;
        final first = firstFailure ?? now;
        await p.setInt(_k('failCount'), fc);
        await _setDate(p, 'firstFailure', first);

        // A confirmed lapse takes precedence over failed checks.
        if (expiredSince != null) return _lapsed(expiredSince, now);

        final exhausted = fc >= config.maxFailedRuns ||
            now.difference(first) >= config.maxFailureWindow;
        if (exhausted) {
          return const GuardResult(
            GuardDecision.revoked,
            message: 'Access has been revoked because your subscription could '
                'not be verified. Restore your subscription to continue.',
          );
        }
        return GuardResult(
          GuardDecision.allowedWithWarning,
          message: 'We could not verify your subscription ($reason). Unless a '
              'valid subscription is confirmed, access will shortly be revoked.',
        );
    }
  }

  GuardResult _lapsed(DateTime since, DateTime now) {
    final endsAt = since.add(config.expiredGrace);
    if (!now.isBefore(endsAt)) {
      return GuardResult(
        GuardDecision.revoked,
        accessEndsAt: endsAt,
        message: 'No active subscription was found, so access has ended. '
            'Subscribe or renew to continue.',
      );
    }
    return GuardResult(
      GuardDecision.grace,
      accessEndsAt: endsAt,
      message: 'No active subscription was found. Access will cease within '
          '${config.expiredGrace.inHours} hours unless you subscribe or renew.',
    );
  }
}
