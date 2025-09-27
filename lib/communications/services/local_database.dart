import 'package:swan_sync/communications/util/fallback/fallback.dart';
import 'package:swan_sync/communications/util/communications.dart';
import 'package:swan_sync/data/request_type.dart';
import 'package:swan_sync/data/i_syncable.dart';
import 'package:swan_sync/swan_sync.dart';

import 'package:hive_flutter/hive_flutter.dart';

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:async';

void _log(String message) => developer.log(message, name: 'LocalDatabase');
void _errorLog(String message, Object error, [StackTrace? stackTrace]) =>
    developer.log(message, error: error, stackTrace: stackTrace, name: 'LocalDatabase');

class LocalDatabase {
  static final LocalDatabase _instance = LocalDatabase._internal();
  factory LocalDatabase() => _instance;
  LocalDatabase._internal();

  /// List of registered ISyncable types for dynamic model creation
  Future<LocalDatabase> initialize([String? subDir]) => Hive.initFlutter(subDir).then((_) => this);

  /// Find the correct ISyncable prototype by table name
  ISyncable? _findPrototypeByTableName(String table) => SwanSync.prototypeFor(table);

  /// Find the type adapter for a given table name
  TypeAdapter? _findAdapterByTableName(String table) {
    return SwanSync.registeredTypes
        .where((entry) => entry.prototype.tableName == table)
        .firstOrNull
        ?.adapter;
  }

  /// Get or create a box for a specific table (keeping original method for compatibility)
  Box<Map<dynamic, dynamic>> _box(String table) => Hive.box<Map<dynamic, dynamic>>(table);

  /// Store or update an item in the local database using type adapters
  Future<ISyncable?> _storeItem(ISyncable item) async {
    try {
      // Try to use the strongly-typed box approach first
      final adapter = _findAdapterByTableName(item.tableName);
      if (adapter != null) {
        // We can store the object directly using its type adapter
        final box = Hive.box(item.tableName);
        await box.put(item.uuid, item);
        return item;
      } else {
        // Fallback to the original Map-based approach
        await _box(item.tableName).put(item.uuid, item.toHiveData());
        return item;
      }
    } catch (e) {
      _errorLog('Error storing item: $e', e, StackTrace.current);
    }
    return null;
  }

  /// Get an item by UUID from a specific table
  ISyncable? getItem(String table, String uuid) {
    try {
      final adapter = _findAdapterByTableName(table);
      final box = Hive.box(table);
      final data = box.get(uuid);

      if (data == null) return null;

      if (adapter != null && data is ISyncable) {
        // Direct return if we have a strongly-typed object
        return data;
      } else {
        // Fallback to manual conversion for Map-based storage
        final prototype = _findPrototypeByTableName(table);
        if (prototype == null) {
          _log('No prototype found for table: $table');
          return null;
        }
        return prototype.fromHiveData(Map<String, dynamic>.from(data));
      }
    } catch (e) {
      _errorLog('Error getting item: $e', e, StackTrace.current);
      return null;
    }
  }

  ISyncable? getItemById(String table, int oid) {
    try {
      final adapter = _findAdapterByTableName(table);
      final box = Hive.box(table);

      if (adapter != null) {
        // Try to find the item directly if we have a strongly-typed box
        try {
          final item = box.values.cast<ISyncable>().firstWhere((item) => item.oid == oid);
          return item;
        } catch (e) {
          return null; // Item not found
        }
      } else {
        // Fallback to Map-based approach
        final prototype = _findPrototypeByTableName(table);
        if (prototype == null) {
          _log('No prototype found for table: $table');
          return null;
        }
        final data = _box(table).values.firstWhere((item) => item['oid'] == oid, orElse: () => {});
        if (data.isEmpty) return null;
        return prototype.fromHiveData(Map<String, dynamic>.from(data));
      }
    } catch (e) {
      _errorLog('Error getting item: $e', e, StackTrace.current);
      return null;
    }
  }

  /// Get all items from a specific table (excludes deleted items by default)
  List<ISyncable> getAllItems(String tableName, {bool includeDeleted = false}) {
    try {
      final adapter = _findAdapterByTableName(tableName);
      final box = Hive.box(tableName);
      final List<ISyncable> items = [];

      if (adapter != null) {
        // Direct casting for strongly-typed boxes
        for (final data in box.values) {
          try {
            if (data is ISyncable) {
              if (!includeDeleted && data.isDeleted) continue;
              items.add(data);
            }
          } catch (e) {
            _errorLog('Error processing strongly-typed item from box: $e', e, StackTrace.current);
          }
        }
      } else {
        // Fallback to Map-based approach
        final prototype = _findPrototypeByTableName(tableName);
        if (prototype == null) {
          _log('No prototype found for table: $tableName');
          return [];
        }
        for (final data in box.values) {
          try {
            final item = prototype.fromHiveData(Map<String, dynamic>.from(data));
            if (!includeDeleted && item.isDeleted) continue;
            items.add(item);
          } catch (e) {
            _errorLog('Error parsing item from box: $e', e, StackTrace.current);
          }
        }
      }
      return items;
    } catch (e) {
      _errorLog('Error getting all items: $e', e, StackTrace.current);
      return [];
    }
  }

  /// Get items that need to be synced to the server (oid == -1)
  Future<List<ISyncable>> getItemsNeedingSync(String tableName) async {
    try {
      return getAllItems(tableName).where((item) => item.needsSync).toList();
    } catch (e) {
      _errorLog('Error getting items needing sync: $e', e, StackTrace.current);
      return [];
    }
  }

  /// Delete an item (hard delete)
  Future<void> deleteSync(String tableName, String uuid) async {
    try {
      await _box(tableName).delete(uuid);
    } catch (e) {
      _errorLog('Error deleting item: $e', e, StackTrace.current);
      rethrow;
    }
  }

  /// Handle conflict resolution for getAll sync
  /// Removes local items that don't exist on server (were deleted remotely)
  /// Sends delete requests for items that were locally deleted while offline
  Future<SyncConflictResult> getAllSync(String tableName, List<ISyncable> serverItems) async {
    try {
      _log('Handling getAll sync for table: $tableName with ${serverItems.length} server items');
      final localItems = getAllItems(tableName, includeDeleted: true);
      final serverUuids = serverItems.map((item) => item.uuid).toSet();

      int deleted = 0;
      int updated = 0;
      int added = 0;
      int deletedOnServer = 0;

      for (final localItem in localItems) {
        if (localItem.isDeleted && localItem.oid != -1) {
          try {
            final prototype = _findPrototypeByTableName(tableName);
            if (prototype != null) {
              var r = await Communications.request(
                prototype,
                null,
                localItem.uuid,
                oid: localItem.oid,
                delete: true,
              );
              if (r.statusCode == 200 || r.statusCode == 204) {
                _log('Successfully deleted ${localItem.oid} on server');
                await deleteSync(tableName, localItem.uuid);
                deletedOnServer++;
              } else {
                _errorLog(
                  'Server failed to delete ${localItem.oid}: ${r.statusCode} ${r.body}',
                  Exception('Server delete failed'),
                  StackTrace.current,
                );
              }
            }
          } catch (e) {
            _errorLog('Failed to delete ${localItem.oid} on server: $e', e, StackTrace.current);
          }
        }
      }

      for (final localItem in localItems) {
        if (localItem.oid != -1 && !localItem.isDeleted && !serverUuids.contains(localItem.uuid)) {
          await deleteSync(tableName, localItem.uuid);
          deleted++;
          _log('Deleted local item ${localItem.oid} - not found on server');
        }
      }

      final localItemsByUuid = {for (var item in localItems) item.uuid: item};

      for (final serverItem in serverItems) {
        final localItem = localItemsByUuid[serverItem.uuid];
        if (localItem == null) {
          await updateItem(serverItem);
          added++;
        } else {
          final result = await _resolveConflict(localItem, serverItem);
          if (result.isStored || result.isTimestampUpdated) updated++;
        }
      }

      _log('GetAll sync completed: N=$added, U=$updated, D=$deleted, SD=$deletedOnServer');
      if (deleted > 0 || updated > 0 || added > 0 || deletedOnServer > 0) {
        return SyncConflictResult.stored;
      } else {
        return SyncConflictResult.noChanges;
      }
    } catch (e) {
      _errorLog('Error handling getAll sync: $e', e, StackTrace.current);
      return SyncConflictResult.error;
    }
  }

  /// Handle incoming data from FCM or API with conflict resolution
  Future<SyncConflictResult> incomingSync(ISyncable incomingData) async {
    try {
      _log('Handling incoming data: ${incomingData.uuid}');
      final existingItem = getItem(incomingData.tableName, incomingData.uuid);
      if (existingItem == null) {
        await updateItem(incomingData);
        _log('Stored new item: ${incomingData.uuid}');
        return SyncConflictResult.stored;
      }
      return await _resolveConflict(existingItem, incomingData);
    } catch (e) {
      _errorLog('Error handling incoming data: $e', e, StackTrace.current);
      return SyncConflictResult.error;
    }
  }

  Future<SyncConflictResult> _resolveConflict(ISyncable local, ISyncable incoming) async {
    _log('Resolving conflict for: ${incoming.oid}::${local.uuid}');
    Future<SyncConflictResult> updateTimestampLocally() async {
      await updateItem(local.copyWith(oid: incoming.oid, updatedAt: incoming.updatedAt));
      _log('Updated timestamps for: ${local.uuid}');
      return SyncConflictResult.timestampUpdated;
    }

    Future<SyncConflictResult> storeIncomingData() async {
      await updateItem(incoming);
      _log('Stored incoming data for: ${incoming.oid}');
      return SyncConflictResult.stored;
    }

    bool haveSameContent = local.hasSameContentAs(incoming);

    if (local.isNewerThan(incoming)) {
      if (haveSameContent) {
        return updateTimestampLocally();
      } else {
        _log('Local data is newer, needs server update: ${incoming.oid}');
        return SyncConflictResult.needsServerUpdate;
      }
    } else if (incoming.isNewerThan(local)) {
      if (haveSameContent) {
        return updateTimestampLocally();
      } else {
        return storeIncomingData();
      }
    } else {
      if (haveSameContent) {
        _log('No changes needed for: ${local.oid}');
        return SyncConflictResult.noChanges;
      } else {
        return storeIncomingData();
      }
    }
  }

  /// Monitor the fallback queue's responses and update local db accordingly
  Future<void> monitorFallbackQueue() async {
    Fallback.fallbackQueueStream.listen((event) async {
      _log("Fallback event received: $event ${json.decode(event.response.body)}");
      final result = event.response;
      final prototype = _findPrototypeByTableName(event.tableName)!;
      final data = json.decode(result.body);
      switch (event.type) {
        case RequestType.GET:
        case RequestType.POST:
        case RequestType.PUT:
          incomingSync(prototype.fromServerData(data));
          break;
        case RequestType.GET_ALL:
          getAllSync(event.tableName, data.map((json) => prototype.fromServerData(json)));
          break;
        case RequestType.DELETE:
          deleteSync(event.tableName, event.uuid);
          break;
      }
    });
  }

  /// Update an existing item locally (will need to be synced)
  Future<ISyncable?> updateItem(ISyncable updatedItem) => _storeItem(updatedItem);

  /// Mark an item as synced (update oid from server)
  Future<void> markItemAsSynced(String tableName, String uuid, int serverOid) async {
    try {
      final item = getItem(tableName, uuid);
      if (item != null) {
        await updateItem(item.copyWith(oid: serverOid));
        _log('Marked item as synced: $uuid with oid: $serverOid');
      }
    } catch (e) {
      _errorLog('Error marking item as synced: $e', e, StackTrace.current);
    }
  }

  /// Get stream of changes for a specific table
  Stream<List<ISyncable>> watchTable(String table) {
    return _box(table).watch().asyncMap((_) => getAllItems(table));
  }

  /// Clear all data for a specific table
  Future<int> clearTable(String tableName) async {
    try {
      _log('Clearing table: $tableName');
      return await _box(tableName).clear();
    } catch (e) {
      _errorLog('Error clearing table: $e', e, StackTrace.current);
      return -1;
    }
  }

  /// Get all registered table names
  List<String> getRegisteredTableNames() => SwanSync.tableNames;

  /// Close all boxes
  Future<void> dispose() async => await Hive.close();
}

/// Result of sync conflict resolution
enum SyncConflictResult {
  stored, // stored incoming
  needsServerUpdate, // local is newer, update on server
  timestampUpdated, // superficial timestamp difference; local timestamp updated
  noChanges, // do nothing
  error; // something went wrong

  bool get isStored => this == SyncConflictResult.stored;
  bool get isTimestampUpdated => this == SyncConflictResult.timestampUpdated;
}
