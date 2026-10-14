import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:subscription_guard/subscription_guard.dart';

/// Returns queued outcomes in order, then CheckUnknown once the queue is empty.
class FakeChecker implements EntitlementChecker {
  final List<CheckOutcome> queue;
  int calls = 0;
  FakeChecker(this.queue);

  @override
  Future<CheckOutcome> check() async {
    calls++;
    if (queue.isEmpty) return const CheckUnknown('no outcome queued');
    return queue.removeAt(0);
  }
}

void main() {
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 10, 14, 12);
  });

  SubscriptionGuard guardWith(EntitlementChecker checker) =>
      SubscriptionGuard(appId: 'test', checker: checker, clock: () => now);

  group('valid subscription', () {
    test('is trusted for the recheck window without asking the store', () async {
      final checker = FakeChecker([
        CheckValid(now.add(const Duration(days: 30))),
        CheckValid(now.add(const Duration(days: 60))),
      ]);
      final guard = guardWith(checker);

      expect((await guard.evaluate()).decision, GuardDecision.allowed);
      now = now.add(const Duration(days: 6));
      expect((await guard.evaluate()).decision, GuardDecision.allowed);
      expect(checker.calls, 1);
    });

    test('is re-checked after 7 days', () async {
      final checker = FakeChecker([
        CheckValid(now.add(const Duration(days: 30))),
        CheckValid(now.add(const Duration(days: 60))),
      ]);
      final guard = guardWith(checker);

      await guard.evaluate();
      now = now.add(const Duration(days: 8));
      expect((await guard.evaluate()).decision, GuardDecision.allowed);
      expect(checker.calls, 2);
    });

    test('recheck is capped by the token expiry when that comes sooner', () async {
      final checker = FakeChecker([
        CheckValid(now.add(const Duration(days: 2))),
        CheckValid(now.add(const Duration(days: 30))),
      ]);
      final guard = guardWith(checker);

      await guard.evaluate();
      now = now.add(const Duration(days: 3));
      await guard.evaluate();
      expect(checker.calls, 2);
    });
  });

  group('positively expired', () {
    test('warns with grace, then revokes after 48 hours', () async {
      final checker = FakeChecker(List.generate(3, (_) => const CheckExpired()));
      final guard = guardWith(checker);

      final first = await guard.evaluate();
      expect(first.decision, GuardDecision.grace);
      expect(first.message, contains('48 hours'));

      now = now.add(const Duration(hours: 47));
      expect((await guard.evaluate()).decision, GuardDecision.grace);

      now = now.add(const Duration(hours: 2));
      expect((await guard.evaluate()).decision, GuardDecision.revoked);
    });

    test('a failed check after a confirmed lapse keeps the lapse rules', () async {
      final checker = FakeChecker([
        const CheckExpired(),
        const CheckUnknown('offline'),
      ]);
      final guard = guardWith(checker);

      await guard.evaluate();
      now = now.add(const Duration(hours: 1));
      expect((await guard.evaluate()).decision, GuardDecision.grace);
    });

    test('renewal clears the lapse', () async {
      final checker = FakeChecker([
        const CheckExpired(),
        CheckValid(now.add(const Duration(days: 30))),
      ]);
      final guard = guardWith(checker);

      await guard.evaluate();
      now = now.add(const Duration(hours: 10));
      expect((await guard.evaluate()).decision, GuardDecision.allowed);
    });
  });

  group('no response from the store', () {
    test('warns on failed runs 1 to 3 and revokes on run 4', () async {
      final checker = FakeChecker(
          List.generate(4, (_) => const CheckUnknown('offline')));
      final guard = guardWith(checker);

      for (var run = 1; run <= 3; run++) {
        final r = await guard.evaluate();
        expect(r.decision, GuardDecision.allowedWithWarning, reason: 'run $run');
        expect(r.message, contains('access will shortly be revoked'));
        now = now.add(const Duration(hours: 1));
      }
      expect((await guard.evaluate()).decision, GuardDecision.revoked);
    });

    test('revokes once 7 days have passed since the first failure', () async {
      final checker = FakeChecker([
        const CheckUnknown('offline'),
        const CheckUnknown('offline'),
      ]);
      final guard = guardWith(checker);

      expect((await guard.evaluate()).decision, GuardDecision.allowedWithWarning);
      now = now.add(const Duration(days: 7));
      expect((await guard.evaluate()).decision, GuardDecision.revoked);
    });

    test('a successful check resets the failure count', () async {
      final checker = FakeChecker([
        const CheckUnknown('offline'),
        const CheckUnknown('offline'),
        CheckValid(now.add(const Duration(days: 30))),
        const CheckUnknown('offline'),
      ]);
      final guard = guardWith(checker);

      await guard.evaluate();
      await guard.evaluate();
      expect((await guard.evaluate()).decision, GuardDecision.allowed);

      now = now.add(const Duration(days: 1));
      final after = await guard.evaluate();
      expect(after.decision, GuardDecision.allowedWithWarning);
      expect(after.message, contains('access will shortly be revoked'));
    });

    test('a timeout counts as a failed run', () async {
      final slow = _SlowChecker();
      final guard = SubscriptionGuard(
        appId: 'test',
        checker: slow,
        config: const GuardConfig(checkTimeout: Duration(milliseconds: 10)),
        clock: () => now,
      );
      final r = await guard.evaluate();
      expect(r.decision, GuardDecision.allowedWithWarning);
      expect(r.message, contains('timeout'));
    });
  });

  test('a stored check time in the future revokes access', () async {
    final checker = FakeChecker([CheckValid(now.add(const Duration(days: 30)))]);
    final guard = guardWith(checker);
    await guard.evaluate();

    now = now.subtract(const Duration(days: 1));
    final r = await guard.evaluate();
    expect(r.decision, GuardDecision.revoked);
    expect(r.message, contains('clock'));
  });

  test('separate app ids do not share state', () async {
    final a = SubscriptionGuard(
      appId: 'radiospy',
      checker: FakeChecker([CheckValid(now.add(const Duration(days: 30)))]),
      clock: () => now,
    );
    final b = SubscriptionGuard(
      appId: 'airfieldspy',
      checker: FakeChecker([const CheckUnknown('offline')]),
      clock: () => now,
    );
    await a.evaluate();
    expect((await b.evaluate()).decision, GuardDecision.allowedWithWarning);
  });
}

class _SlowChecker implements EntitlementChecker {
  @override
  Future<CheckOutcome> check() =>
      Future.delayed(const Duration(seconds: 1), () => const CheckExpired());
}
