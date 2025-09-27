import 'package:swan_sync/communications/util/api_exceptions.dart';
import 'package:swan_sync/communications/util/communications.dart';
import 'package:swan_sync/data/i_syncable.dart';
import 'package:swan_sync/swan_sync.dart';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:flutter/foundation.dart';

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:async';

_log(String message) => developer.log(message);

class Api {
  static final Api _instance = Api._internal();
  factory Api() => _instance;
  Api._internal();

  static const Duration timeout = Duration(seconds: 30);

  /// Can be overridden by setting the headers property on the Api instance.
  /// If not set, uses defaultHeaders.
  Map<String, String> get configuredHeaders =>
      _configuredHeaders.isNotEmpty ? _configuredHeaders : defaultHeaders;

  /// Default headers for all API requests
  /// Content-Type and Accept are set to application/json
  /// Device-ID is set to the device token from SyncController or 'anonymous swan v3' if unavailable
  ///
  /// Combines default headers with any additional headers provided, with additional headers taking precedence
  Map<String, String> get defaultHeaders => {..._defaultHeaders, ..._configuredHeaders};

  Map<String, String> get _defaultHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'device-id': deviceToken ?? 'anonymous swan',
  };

  Map<String, String> _configuredHeaders = {};
  set headers(Map<String, String> headers) {
    _configuredHeaders = headers;
  }

  static String? deviceToken = 'anonymous swan';

  Future<Api> initialize() async {
    // TODO: requestpermission? shouldn't have to since we're dealing with data messages
    if (defaultTargetPlatform == TargetPlatform.iOS)
      deviceToken = await FirebaseMessaging.instance.getAPNSToken();
    else
      deviceToken = await FirebaseMessaging.instance.getToken();
    _log('FCM Device Token: $deviceToken');
    return this;
  }

  /// Find the correct ISyncable prototype by table name
  ISyncable? _findPrototypeByTableName(String tableName) => SwanSync.prototypeFor(tableName);

  /// Get all items for a specific syncable type
  Future<List<ISyncable>> getAll(ISyncable prototype, {bool storeFallback = true}) async {
    try {
      _log('Fetching all items for table: ${prototype.tableName}');

      final response = await Communications.request(
        prototype,
        null,
        "<getAll has no UUID>",
        headers: defaultHeaders,
        storeFallback: storeFallback,
      );

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        final List<ISyncable> items = [];

        for (final json in jsonList) {
          final String? tableName = json['tableName'];
          if (tableName == null) {
            throw ApiException('Server response missing tableName field: $json');
          }

          final modelPrototype = _findPrototypeByTableName(tableName);
          if (modelPrototype == null) {
            throw ApiException('No registered type found for tableName: $tableName');
          }

          items.add(modelPrototype.fromServerData(json));
        }

        _log('Successfully fetched ${items.length} items for ${prototype.tableName}');
        return items;
      } else {
        throw ApiException('Failed to fetch data: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Error fetching all data for ${prototype.tableName}: $e');
      rethrow;
    }
  }

  /// Get item by ID for a specific syncable type
  Future<ISyncable> getById(ISyncable prototype, int id) async {
    try {
      _log('Fetching item by ID: $id for table: ${prototype.tableName}');

      final response = await Communications.request(
        prototype,
        null,
        "<getting by ID has no UUID>",
        oid: id,
        headers: defaultHeaders,
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);

        final String? tableName = json['tableName'];
        if (tableName == null) {
          throw ApiException('Server response missing tableName field: $json');
        }

        final modelPrototype = _findPrototypeByTableName(tableName);
        if (modelPrototype == null) {
          throw ApiException('No registered type found for tableName: $tableName');
        }

        final item = modelPrototype.fromServerData(json);
        _log('Successfully fetched item: ${item.uuid}');
        return item;
      } else if (response.statusCode == 404) {
        throw NotFoundException('Item not found: $id');
      } else {
        throw ApiException('Failed to fetch item: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Error fetching item by ID: $e');
      rethrow;
    }
  }

  /// Create new item
  Future<ISyncable> create(ISyncable data) async {
    try {
      _log('Creating item: ${data.uuid} for table: ${data.tableName}');

      final response = await Communications.request(data, data, data.uuid, headers: defaultHeaders);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseJson = json.decode(response.body);

        final String? tableName = responseJson['tableName'];
        if (tableName == null) {
          throw ApiException('Server response missing tableName field: $responseJson');
        }

        final modelPrototype = _findPrototypeByTableName(tableName);
        if (modelPrototype == null) {
          throw ApiException('No registered type found for tableName: $tableName');
        }

        final createdItem = modelPrototype.fromServerData(responseJson);
        _log('Successfully created item: ${createdItem.oid}');
        return createdItem;
      } else {
        throw ApiException('Failed to create item: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Error creating item: $e');
      rethrow;
    }
  }

  /// Update existing item
  Future<ISyncable> update(ISyncable data, int id) async {
    try {
      _log('Updating item: $id for table: ${data.tableName}');

      final response = await Communications.request(
        data,
        data,
        data.uuid,
        oid: id,
        headers: defaultHeaders,
      );

      if (response.statusCode == 200) {
        final responseJson = json.decode(response.body);

        final String? tableName = responseJson['tableName'];
        if (tableName == null) {
          throw ApiException('Server response missing tableName field: $responseJson');
        }

        final modelPrototype = _findPrototypeByTableName(tableName);
        if (modelPrototype == null) {
          throw ApiException('No registered type found for tableName: $tableName');
        }

        final updatedItem = modelPrototype.fromServerData(responseJson);
        _log('Successfully updated item: ${updatedItem.oid}');
        return updatedItem;
      } else if (response.statusCode == 404) {
        throw NotFoundException('Item not found: $id');
      } else {
        throw ApiException('Failed to update item: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Error updating item: $e');
      rethrow;
    }
  }

  /// Delete item
  Future<void> delete(ISyncable prototype, int id) async {
    try {
      _log('Deleting item: $id for table: ${prototype.tableName}');

      var uuid = SwanSync.database.getItemById(prototype.tableName, id)?.uuid ?? 'unknown UUID';

      final response = await Communications.request(
        prototype,
        null,
        uuid,
        oid: id,
        delete: true,
        headers: defaultHeaders,
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        _log('Successfully deleted item: $id');
      } else if (response.statusCode == 404) {
        throw NotFoundException('Item not found: $id');
      } else {
        throw ApiException('Failed to delete item: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _log('Error deleting item: $e');
      rethrow;
    }
  }

  /// Check if the server is reachable for any registered type
  Future<bool> isServerReachable() async {
    if (SwanSync.registeredTypes.isEmpty) return false;
    try {
      final prototype = SwanSync.prototypes.first;
      // not ideal to use the getall endpoint, in future could implement a lightweight ping endpoint
      final response = await Communications.request(
        prototype,
        null,
        "<server reachability check has no UUID>",
        headers: defaultHeaders,
      );
      return response.statusCode < 500;
    } catch (e) {
      return false;
    }
  }

  /// Get prototype for a table name
  ISyncable? getPrototypeForTable(String tableName) => _findPrototypeByTableName(tableName);
}
