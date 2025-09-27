part of 'fallback.dart';

mixin _RetryTimerMixin {
  static Future<bool> currentRequestFinished = Future.value(true);
  static bool underway = false;
  static Timer? _retryTimer;
  static void _startRetryTimer(Future<bool> Function() processQueues) {
    if (_retryTimer?.isActive == true) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (underway)
        return;
      else
        underway = true;
      if (await currentRequestFinished) currentRequestFinished = processQueues();
    });

    _log('Started fallback queue retry timer');
  }
}
