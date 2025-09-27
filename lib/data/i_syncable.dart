/// Interface that all syncable models must implement
/// Provides dynamic endpoint configuration and data transformation
abstract class ISyncable {
  /// Server-side entry ID (-1 means needs sync)
  int get oid;

  /// Client-side UUID (always required)
  String get uuid;

  /// Created timestamp
  DateTime get createdAt;

  /// Updated timestamp
  DateTime get updatedAt;

  /// Whether this item needs to be synced to server (oid == -1)
  bool get needsSync => oid == -1;

  /// Whether this item is marked for deletion locally
  bool get isDeleted;

  // API Sync Endpoint definitions - each model defines its own routes
  /// Table name for this model type (used for Hive box and server identification)
  String get tableName;

  /// GET /api/endpoint - get all items of this type
  String get getAllEndpoint;

  /// GET /api/endpoint/{id} - get specific item by ID
  String get getByIdEndpoint;

  /// POST /api/endpoint - create new item
  String get postEndpoint;

  /// PUT /api/endpoint/{id} - update existing item
  String get putEndpoint;

  /// DELETE /api/endpoint/{id} - delete item
  String get deleteEndpoint;

  /// Convert model to server-compatible JSON format
  Map<String, dynamic> toServerData();

  /// Create model instance from server response data
  ISyncable fromServerData(Map<String, dynamic> serverData);

  /// Create a copy of this model with updated fields
  ISyncable copyWith({
    int? oid,
    String? uuid,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  });

  /// Check if this item is newer than another based on updatedAt
  bool isNewerThan(ISyncable other) => updatedAt.isAfter(other.updatedAt);

  /// Check if this item has the same content as another (ignoring timestamps and oid)
  bool hasSameContentAs(ISyncable other);

  /// Convert to Hive-compatible format for local storage
  Map<String, dynamic> toHiveData();

  /// Create model instance from Hive stored data
  ISyncable fromHiveData(Map<String, dynamic> hiveData);
}
