import 'package:swan_sync/communications/services/api.dart';
import 'package:swan_sync/communications/services/local_database.dart';
import 'package:swan_sync/communications/util/fallback/fallback.dart';
import 'package:swan_sync/data/i_syncable.dart';
import 'package:swan_sync/data/models/data_message_response.dart';
import 'package:swan_sync/swan_sync.dart';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'dart:developer' as developer;
import 'dart:async';

_log(String message) => developer.log(message, name: 'SyncController');
_errorLog(String message, Object error, [StackTrace? stackTrace]) =>
    developer.log(message, error: error, stackTrace: stackTrace, name: 'SyncController');

class SyncController {
  static final SyncController _instance = SyncController._internal();
  factory SyncController() => _instance;
  SyncController._internal();

  final LocalDatabase database = LocalDatabase();
  final Api _api = SwanSync.api;

  StreamSubscription<RemoteMessage>? _fcmSubscription;

  bool _isInitialized = false;

  static String? deviceToken = "anonymous swan v2";
  Timer? autoTriggerSyncTimer;

  /// Initialize the sync controller and set up FCM listeners
  Future<void> initialize({bool performAutoSync = true}) async {
    if (_isInitialized) return;
    database.monitorFallbackQueue();
    await _api.initialize();
    FirebaseMessaging.onMessage.listen(_handleFcmMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleFcmMessage);
    _isInitialized = true;
    if (performAutoSync) autoSyncOnLaunch();
    resetFullSyncTimer();
  }

  void triggerFullSync(Timer timer) {
    Fallback.getTotalQueueSize()
        .then((size) {
          if (size > 0) return _log('Skipping full sync due to pending fallback queue size: $size');
          _log('Auto-triggering full sync of all tables');
          fullSyncAllTables(withFallback: false);
        })
        .catchError((e) {
          _errorLog('Error checking fallback queue size: $e', e, StackTrace.current);
          fullSyncAllTables(withFallback: false);
        });
  }

  void resetFullSyncTimer() {
    autoTriggerSyncTimer?.cancel();
    autoTriggerSyncTimer = Timer.periodic(const Duration(seconds: 45), triggerFullSync);
  }

  Future<void> autoSyncOnLaunch() async {
    try {
      _log('Starting auto-sync on launch');
      await fullSyncAllTables();
      _log('Auto-sync on launch completed successfully');
    } catch (e) {
      _log('Error during auto-sync on launch: $e');
    }
  }

  /// Get prototype for a given table name
  ISyncable? _getPrototypeByTableName(String tableName) => SwanSync.prototypeFor(tableName);

  /// Handle FCM messages
  Future<void> _handleFcmMessage(RemoteMessage message) async {
    try {
      if (message.data.isEmpty) {
        return _log('FCM message has no data payload');
      } else {
        _log('[FCM] Received FCM message: ${message.data}');
        // resetFullSyncTimer(); normally would reset countdown for fullsync here until later,
        // but sometimes multiple messages might not arrive or server will fail to send
        // them so it's best to force an occasional fullsync anyway
      }
      final dataMessage = DataMessageResponse.fromFcmPayload(message.data);
      if (dataMessage.isDelete)
        await _handleDeleteFromFcm(dataMessage);
      else
        await _handleUpdateFromFcm(dataMessage);
    } catch (e, stackTrace) {
      _errorLog('Error handling FCM message: $e', e, stackTrace);
    }
  }

  /// Handle delete operations from FCM
  Future<void> _handleDeleteFromFcm(DataMessageResponse dataMessage) async {
    try {
      _log('Handling delete from FCM: ${dataMessage.uuid} in ${dataMessage.tableName}');
      await database.delete(dataMessage.tableName, dataMessage.uuid);
    } catch (e) {
      _errorLog('Error handling delete from FCM: $e', e, StackTrace.current);
    }
  }

  /// Handle update operations from FCM
  Future<void> _handleUpdateFromFcm(DataMessageResponse message) async {
    try {
      _log('Handling update from FCM: ${message.uuid} in ${message.tableName}');
      final prototype = _getPrototypeByTableName(message.tableName);
      if (prototype == null) return _log('No prototype found for table: ${message.tableName}');
      if (message.effectiveId == null)
        return _log('No effective ID in FCM message for ${message.tableName}:${message.uuid}');
      final serverData = await _api.getById(prototype, message.effectiveId!);
      final result = await database.incomingSync(serverData);
      switch (result) {
        case SyncConflictResult.stored:
        case SyncConflictResult.timestampUpdated:
          _log('Local data is older, downloaded from server: ${message.uuid}');
          break;
        case SyncConflictResult.needsServerUpdate:
          _log('Local data is newer, sending to server: ${message.uuid}');
          await _syncLocalItemToServer(message.tableName, message.uuid);
          break;
        case SyncConflictResult.error:
          _log('Error handling FCM update: ${message.uuid}');
          break;
        case SyncConflictResult.noChanges:
          _log('No changes needed for FCM update: ${message.uuid}');
          break;
      }
    } catch (e) {
      _errorLog('Error handling update from FCM: $e', e, StackTrace.current);
    }
  }

  /// Sync a local item to the server
  Future<void> _syncLocalItemToServer(String tableName, String uuid) async {
    try {
      final localItem = database.getItem(tableName, uuid);
      if (localItem == null) return _log('Local item not found for server sync: $uuid');
      ISyncable? result;
      if (localItem.needsSync) {
        // upload new
        result = await _api.create(localItem);
        _log('Created new item on server: ${localItem.uuid}');
      } else {
        // upload update
        result = await _api.update(localItem, localItem.oid);
        _log('Updated existing item on server: ${localItem.uuid}');
      }
      // update local (adds oid, in the future might add other data)
      await database.updateItem(result);
    } catch (e) {
      _errorLog('Error syncing local item to server: $e', e, StackTrace.current);
    }
  }

  /// Create a new item locally and sync to server
  Future<ISyncable> createItem(ISyncable item) async {
    try {
      _log('Creating new item: ${item.uuid} in ${item.tableName}');
      await database.updateItem(item);
      try {
        final serverResult = await _api.create(item);
        await database.updateItem(serverResult);
        return serverResult;
      } catch (e) {
        _errorLog('Failed to sync new item to server immediately: $e', e, StackTrace.current);
      }
      return item;
    } catch (e) {
      _errorLog('Error creating item: $e', e, StackTrace.current);
      rethrow;
    }
  }

  /// Update an existing item locally and sync to server
  Future<ISyncable?> updateItem(ISyncable item) async {
    try {
      _log('Updating item: ${item.uuid} in ${item.tableName}');
      await database.updateItem(item);
      try {
        ISyncable? serverResult;
        if (item.needsSync)
          serverResult = await _api.create(item);
        else
          serverResult = await _api.update(item, item.oid);
        await database.updateItem(serverResult);
        return serverResult;
      } catch (e) {
        _errorLog('Failed to sync updated item to server immediately: $e', e, StackTrace.current);
      }
      return item;
    } catch (e) {
      _errorLog('Error updating item: $e', e, StackTrace.current);
      rethrow;
    }
  }

  /// Delete an item locally and sync to server
  Future<void> deleteItem(String tableName, String uuid) async {
    try {
      _log('Deleting item: $uuid from $tableName');
      final localItem = database.getItem(tableName, uuid);
      if (localItem == null) return _log('Item not found for deletion: $uuid');
      if (!localItem.needsSync) {
        try {
          _api.delete(localItem, localItem.oid).then((_) {
            _log('Successfully deleted item on server: ${localItem.oid}');
            database.delete(tableName, uuid);
          });
        } catch (e) {
          _errorLog('Failed to delete on server: $e, setting flag to deleted', e);
        }
        final deletedItem = localItem.copyWith(isDeleted: true, updatedAt: DateTime.now().toUtc());
        await database.updateItem(deletedItem);
      } else {
        await database.delete(tableName, uuid);
        _log('Deleted unsynced item locally: $uuid');
      }
    } catch (e) {
      _errorLog('Error deleting item: $e', e, StackTrace.current);
      rethrow;
    }
  }

  /// Get all items from a specific table
  List<ISyncable> getItems(String tableName) => database.getAllItems(tableName);

  /// Get a specific item by UUID
  ISyncable? getItem(String tableName, String uuid) => database.getItem(tableName, uuid);

  /// Watch changes to a specific table
  Stream<List<ISyncable>> watchTable(String tableName) => database.watchTable(tableName);

  /// Sync all pending items for a specific table
  Future<void> syncPendingItems(String tableName) async {
    try {
      _log('Syncing pending items for table: $tableName');
      final pendingItems = await database.getItemsNeedingSync(tableName);
      for (final item in pendingItems) await _syncLocalItemToServer(tableName, item.uuid);
      _log('Synced ${pendingItems.length} pending items for $tableName');
    } catch (e) {
      _errorLog('Error syncing pending items: $e', e, StackTrace.current);
    }
  }

  /// Perform full sync for a specific table (getAll + conflict resolution)
  Future<void> fullSyncTable(String tableName, {bool withFallback = true}) async {
    try {
      _log('Performing full sync for table: $tableName');
      await syncPendingItems(tableName);
      final prototype = _getPrototypeByTableName(tableName);
      if (prototype == null) return _log('No prototype found for this table: $tableName');
      final serverItems = await _api.getAll(prototype, storeFallback: withFallback);
      if (serverItems.isNotEmpty) {
        final result = await database.getAllSync(tableName, serverItems);
        _log('GetAll sync result for $tableName: $result');
      }
      _log('Full sync completed for table: $tableName');
    } catch (e) {
      _errorLog('Error during full sync for $tableName: $e', e, StackTrace.current);
    }
  }

  /// Perform full sync for all registered tables
  Future<void> fullSyncAllTables({bool withFallback = true}) async {
    try {
      _log('Performing full sync for all tables');
      final tableNames = database.getRegisteredTableNames();
      for (final table in tableNames) await fullSyncTable(table, withFallback: withFallback);
      _log('Full sync completed for all ${tableNames.length} tables');
    } catch (e) {
      _errorLog('Error during full sync of all tables: $e', e, StackTrace.current);
    }
  }

  /// Clear all data for a specific table
  Future<void> clearTable(String tableName) async => await database.clearTable(tableName);

  /// Get list of all registered table names
  List<String> getRegisteredTableNames() => database.getRegisteredTableNames();

  /// Dispose resources
  void dispose() {
    autoTriggerSyncTimer?.cancel();
    _fcmSubscription?.cancel();
  }
}
