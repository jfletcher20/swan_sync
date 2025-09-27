import 'package:json_annotation/json_annotation.dart';

part 'data_message_response.g.dart';

/// Model for handling FCM data message responses
/// Contains minimal data needed to identify and process sync messages
@JsonSerializable()
class DataMessageResponse {
  /// Server-side entry ID (online ID; OID)
  @JsonKey(name: 'id')
  final int? id;

  /// Client-side UUID
  final String uuid;

  /// Table name to identify which model type this belongs to
  final String tableName;

  /// Whether this is a delete operation
  final bool? delete;

  DataMessageResponse({this.id, required this.uuid, required this.tableName, this.delete});

  /// Factory constructor from JSON
  factory DataMessageResponse.fromJson(Map<String, dynamic> json) =>
      _$DataMessageResponseFromJson(json);

  /// Convert to JSON
  Map<String, dynamic> toJson() => _$DataMessageResponseToJson(this);

  /// Create from FCM data payload
  factory DataMessageResponse.fromFcmPayload(Map<String, dynamic> payload) {
    return DataMessageResponse(
      id: int.tryParse((payload['id'] ?? payload['entryId'])?.toString() ?? ''),
      uuid: payload['uuid'] ?? '',
      tableName: payload['tableName'] ?? '',
      delete: payload['delete'] == 'true' || payload['delete'] == true,
    );
  }

  /// Get the effective ID on the server
  int? get effectiveId => id;

  /// Check if this is a delete operation
  bool get isDelete => delete == true;

  @override
  String toString() {
    return 'DataMessageResponse{id: $id, uuid: $uuid, tableName: $tableName, delete: $delete}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DataMessageResponse &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          uuid == other.uuid &&
          tableName == other.tableName &&
          delete == other.delete;

  @override
  int get hashCode => id.hashCode ^ uuid.hashCode ^ tableName.hashCode ^ delete.hashCode;
}
