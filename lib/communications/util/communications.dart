// ignore_for_file: constant_identifier_names

import 'package:swan_sync/communications/util/fallback/fallback.dart';
import 'package:swan_sync/data/request_type.dart';
import 'package:swan_sync/swan_sync.dart';
import 'package:swan_sync/data/i_syncable.dart';

import 'package:http/http.dart' as http;

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:async';

_log(String message) => developer.log(message, name: 'Communications');

abstract class Communications {
  /// Unified request handler for all API interactions
  ///
  /// Determines request type based on parameters and routes accordingly.
  /// If a request fails, it is added to the Fallback queue for retrying later.
  ///
  /// If a body is provided, it is assumed to be a POST or PUT request.
  /// If no body is provided, it is assumed to be a GET or DELETE request.
  /// If [oid] is null, it is assumed to be a GET_ALL or POST request.
  /// If [oid] is not null, it is assumed to be a GET/oid, PUT, or DELETE request.
  /// If [delete] is true, it is assumed to be a DELETE request.
  ///
  ///
  /// By default, empty [headers] will use Api's [defaultHeaders] reference.
  /// The [defaultHeaders] can be
  /// If you want to override with custom headers, provide them here.
  /// If you don't want any headers, provide an empty map ```{}```
  static Future<http.Response> request(
    ISyncable prototype,
    ISyncable? data,
    String uuid, {
    int? oid,
    Map<String, String>? headers,
    bool delete = false,
    bool storeFallback = true,
  }) async {
    headers ??= SwanSync.api.defaultHeaders;
    RequestType? type = RequestType.detectType(oid: oid, body: data != null, delete: delete);
    try {
      _log('Handling request for table: ${prototype.tableName}');
      http.Response response = switch (type) {
        RequestType.GET_ALL => await http
            .get(Uri.parse(prototype.getAllEndpoint), headers: headers)
            .timeout(const Duration(seconds: 10)),
        RequestType.GET => await http
            .get(Uri.parse('${prototype.getByIdEndpoint}/$oid'), headers: headers)
            .timeout(const Duration(seconds: 10)),
        RequestType.POST => await http
            .post(
              Uri.parse(data!.postEndpoint),
              headers: headers,
              body: json.encode(data.toServerData()),
            )
            .timeout(const Duration(seconds: 10)),
        RequestType.PUT => await http
            .put(
              Uri.parse('${data!.putEndpoint}/$oid'),
              headers: headers,
              body: json.encode(data.toServerData()),
            )
            .timeout(const Duration(seconds: 10)),
        RequestType.DELETE => await http
            .delete(Uri.parse('${prototype.deleteEndpoint}/$oid'), headers: headers)
            .timeout(const Duration(seconds: 10)),
        null => throw Exception('Could not determine request type for T:${prototype.tableName}'),
      };

      if ((response.statusCode >= 200 && response.statusCode < 300) || response.statusCode == 404) {
        return response;
      } else {
        _log('Failed for T:${prototype.tableName} with ${response.statusCode}: ${response.body}');
        if (storeFallback) Fallback.addToQueue(type!, prototype.tableName, uuid, oid, data);
        return response;
      }
    } catch (e) {
      if (storeFallback) {
        _log('Error handling request: $e, sending to fallback');
        Fallback.addToQueue(type!, prototype.tableName, uuid, oid, data);
      }
      return http.Response('Error: $e', 500);
    }
  }
}
