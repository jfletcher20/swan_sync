import 'package:swan_sync/data/request_type.dart';
import 'package:swan_sync/swan_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swan_sync/data/i_syncable.dart';

import 'package:http/http.dart' as http;

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:async';

part 'retry_timer_mixin.dart';
part 'queue_types_mixin.dart';

_log(String message) => developer.log(message, name: 'Fallback');

/// Fallback system to queue failed API requests and retry them later
/// Uses SharedPreferences to store queues persistently
/// Processes queues periodically using a timer
/// Streams successful responses for processing by LocalDatabase
/// Handles GET_ALL, GET, POST, PUT, DELETE request types
///
/// Uses defaultHeaders from Api for all retry requests
abstract class Fallback with _RetryTimerMixin, _QueueTypesMixin {
  static void init() => _RetryTimerMixin._startRetryTimer(processQueues);

  /// Only disposes resources used by Fallback; does not clear queues.
  /// To clear queues, use [clearAllQueues].
  static void dispose() {
    _RetryTimerMixin._retryTimer?.cancel();
    _fallbackResponseController.close();
  }

  /// In case queues need to be cleared manually; for example in case of changing accounts.
  static Future<void> clearAllQueues() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final requestType in RequestType.values) {
        final queueKey = _QueueTypesMixin._getQueueKeyForType(requestType);
        await prefs.remove(queueKey);
        _log('Cleared ${requestType.name} queue');
      }
    } catch (e) {
      _log('Error clearing all queues: $e');
    }
  }

  static Future<void> addToQueue(
    RequestType type,
    String tableName,
    String uuid,
    int? oid,
    ISyncable? data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueKey = _QueueTypesMixin._getQueueKeyForType(type);
      final queueJson = prefs.getString(queueKey) ?? '[]';
      final List<dynamic> queue = json.decode(queueJson);

      final queueItem = {
        'type': type.name,
        'tableName': tableName,
        'uuid': uuid,
        'oid': oid,
        'data': data?.toServerData(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // queue.removeWhere((item) => item['uuid'] == uuid && item['tableName'] == tableName);
      queue.add(queueItem);

      await prefs.setString(queueKey, json.encode(queue));
      _log('Added ${type.name} request for $uuid to ${type.name} queue');
    } catch (e) {
      _log('Error adding to fallback queue: $e');
    }
  }

  static Future<bool> processQueues() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      int totalProcessed = 0;
      int totalRemaining = 0;
      for (final requestType in RequestType.values) {
        final queueKey = _QueueTypesMixin._getQueueKeyForType(requestType);
        final queueJson = prefs.getString(queueKey) ?? '[]';
        final List<dynamic> queue = json.decode(queueJson);
        if (queue.isEmpty) continue;
        _log('Processing ${queue.length} items in ${requestType.name} queue');
        final List<dynamic> remainingItems = [];
        for (final item in queue) {
          try {
            final success = await _retryQueueItem(item);
            if (!success) remainingItems.add(item);
            await Future.delayed(const Duration(seconds: 1));
          } catch (e) {
            _log('Error processing ${requestType.name} queue item ${item['uuid']}: $e');
            remainingItems.add(item);
          }
        }
        await prefs.setString(queueKey, json.encode(remainingItems));
        final processed = queue.length - remainingItems.length;
        totalProcessed += processed;
        totalRemaining += remainingItems.length;
        if (queue.isNotEmpty) {
          _log(
            '${requestType.name} queue: $processed processed, ${remainingItems.length} remaining',
          );
        }
      }
      if (totalProcessed > 0 || totalRemaining > 0) {
        _log(
          'Total: $totalProcessed items processed successfully, $totalRemaining remaining across all queues',
        );
        if (totalRemaining == 0)
          SwanSync.syncController.fullSyncAllTables().then((_) {
            _log('Finished triggering full sync after processing fallback queues');
          });
      }
    } catch (e) {
      _log('Error processing fallback queues: $e');
    }
    _RetryTimerMixin.underway = false;
    return true;
  }

  static Future<bool> _retryQueueItem(Map<String, dynamic> item) async {
    try {
      final type = RequestType.values.firstWhere((e) => e.name == item['type']);
      final tableName = item['tableName'] as String;
      final uuid = item['uuid'] as String;
      final oid = item['oid'] as int?;
      final dataJson = item['data'] as Map<String, dynamic>?;
      _log('Retrying ${type.name} request for $uuid');
      final registeredTypes = SwanSync.prototypes;
      ISyncable? prototype;
      for (final registeredType in registeredTypes) {
        if (registeredType.tableName == tableName) {
          prototype = registeredType;
          break;
        }
      }
      if (prototype == null) {
        _log('No registered type found for table: $tableName');
        return false;
      }
      ISyncable? requestData;
      if (dataJson != null) {
        try {
          requestData = SwanSync.database.getItem(prototype.tableName, uuid);
          if ((type == RequestType.POST || type == RequestType.PUT) && requestData == null) {
            _log('Data for ${type.name} request $uuid not found in local DB, removing from queue');
            return true;
          }
        } catch (e) {
          _log('Error reconstructing data from JSON: $e');
          return false;
        }
      }
      http.Response response;
      Uri uri(String endpoint) => Uri.parse(endpoint);
      switch (type) {
        case RequestType.GET_ALL:
          response = await http.get(uri(prototype.getAllEndpoint)).throwOnTimeout(type);
          break;
        case RequestType.GET:
          if (oid == null) {
            _log('OID required for GET request');
            return false;
          }
          response = await http.get(uri('${prototype.getByIdEndpoint}/$oid')).throwOnTimeout(type);
          break;
        case RequestType.POST:
          if (requestData == null) {
            _log('Data required for POST request');
            return false;
          }
          response = await http
              .post(
                uri(requestData.postEndpoint),
                headers: SwanSync.api.defaultHeaders,
                body: json.encode(requestData.toServerData()),
              )
              .throwOnTimeout(type);
          break;
        case RequestType.PUT:
          if (requestData == null || oid == null) {
            _log('Data and OID required for PUT request');
            return false;
          }
          response = await http
              .put(
                uri('${requestData.putEndpoint}/$oid'),
                headers: SwanSync.api.defaultHeaders,
                body: json.encode(requestData.toServerData()),
              )
              .throwOnTimeout(type);
          break;
        case RequestType.DELETE:
          if (oid == null) {
            _log('OID required for DELETE request');
            return false;
          }
          response = await http
              .delete(uri('${prototype.deleteEndpoint}/$oid'), headers: SwanSync.api.defaultHeaders)
              .throwOnTimeout(type);
          break;
      }

      final success =
          (response.statusCode >= 200 && response.statusCode < 300) || response.statusCode == 404;
      if (success) {
        _log('Successfully retried ${type.name} for $uuid (${response.statusCode})');
        _fallbackResponseController.add((
          response: response,
          type: type,
          uuid: uuid,
          tableName: tableName,
        ));
      } else {
        _log('Retry failed for ${type.name} $uuid (${response.statusCode}): ${response.body}');
      }

      return success;
    } catch (e) {
      _log('Error retrying queue item: $e');
      return false;
    }
  }

  /// Store the fallback responses as a stream to be processed by local database service
  static final StreamController<
    ({http.Response response, RequestType type, String uuid, String tableName})
  >
  _fallbackResponseController =
      StreamController<
        ({http.Response response, RequestType type, String uuid, String tableName})
      >.broadcast();

  static Stream<({http.Response response, RequestType type, String uuid, String tableName})>
  get fallbackQueueStream => _fallbackResponseController.stream;

  static Future<int> getTotalQueueSize() async {
    int totalSize = 0;
    for (final requestType in RequestType.values)
      totalSize += await getQueueSizeForType(requestType);
    return totalSize;
  }

  static Future<int> getQueueSizeForType(RequestType type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueKey = _QueueTypesMixin._getQueueKeyForType(type);
      final queueJson = prefs.getString(queueKey) ?? '[]';
      final List<dynamic> queue = json.decode(queueJson);
      return queue.length;
    } catch (e) {
      _log('Error getting queue size for ${type.name}: $e');
      return 0;
    }
  }
}

extension on Future<http.Response> {
  Future<http.Response> throwOnTimeout(
    RequestType type, {
    Duration seconds = const Duration(seconds: 10),
  }) {
    return timeout(
      seconds,
      onTimeout: () => throw TimeoutException('${type.name} request timed out'),
    );
  }
}
