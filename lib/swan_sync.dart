import 'package:swan_sync/communications/services/sync_controller.dart';
import 'package:swan_sync/communications/services/local_database.dart';
import 'package:swan_sync/communications/util/fallback/fallback.dart';
import 'package:swan_sync/communications/services/api.dart';
import 'package:swan_sync/data/i_syncable.dart';

import 'package:hive_flutter/hive_flutter.dart';

abstract class SwanSync {
  static late final SyncController syncController;
  static late final Api api;
  static LocalDatabase get database => syncController.database;

  /// List of registered adapter-prototype pairs
  static final List<({TypeAdapter adapter, ISyncable prototype})> registeredTypes = [];

  /// List of registered TypeAdapters for Hive
  static List<TypeAdapter> get adapters => registeredTypes.map((e) => e.adapter).toList();

  /// List of registered ISyncable prototypes for dynamic model creation
  static List<ISyncable> get prototypes => registeredTypes.map((e) => e.prototype).toList();

  /// List of registered table names for SWAN Sync
  static List<String> get tableNames => registeredTypes.map((e) => e.prototype.tableName).toList();

  /// Initialize SWAN Sync with the provided list of TypeAdapters and ISyncable prototypes.
  /// The adapters are used for Hive storage, while the prototypes are used for dynamic model creation and server communication.
  ///
  /// The [types] parameter is a list of records containing a TypeAdapter and its corresponding ISyncable prototype
  static Future<void> initialize({
    required List<({TypeAdapter adapter, ISyncable prototype})> types,
  }) async {
    // init hive
    await database.initialize();
    // init adapters and open boxes
    for (var (adapter: adapter, prototype: prototype) in types) {
      if (!Hive.isAdapterRegistered(adapter.typeId)) Hive.registerAdapter(adapter);
      if (!Hive.isBoxOpen(prototype.tableName))
        await Hive.openBox(
          prototype.tableName,
        ); // Open without generic type to allow type adapter serialization
      registeredTypes.add((adapter: adapter, prototype: prototype));
    }

    api = Api();
    syncController = SyncController();
    Fallback.init();

    await syncController.initialize(performAutoSync: true);
  }

  static void dispose() {
    syncController.dispose();
    Fallback.dispose();
  }

  static ISyncable? prototypeFor(String tableName) {
    return prototypes.where((type) => type.tableName == tableName).firstOrNull;
  }
}
