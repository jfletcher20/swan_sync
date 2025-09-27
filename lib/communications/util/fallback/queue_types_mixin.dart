part of 'fallback.dart';

mixin _QueueTypesMixin {
  static const String _getQueueKey = 'fallback_queue_get';
  static const String _getAllQueueKey = 'fallback_queue_get_all';
  static const String _postQueueKey = 'fallback_queue_post';
  static const String _putQueueKey = 'fallback_queue_put';
  static const String _deleteQueueKey = 'fallback_queue_delete';

  static String _getQueueKeyForType(RequestType type) {
    return switch (type) {
      RequestType.GET => _getQueueKey,
      RequestType.GET_ALL => _getAllQueueKey,
      RequestType.POST => _postQueueKey,
      RequestType.PUT => _putQueueKey,
      RequestType.DELETE => _deleteQueueKey,
    };
  }
}
