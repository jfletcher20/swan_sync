import 'package:swan_sync/communications/services/sync_controller.dart';
import 'package:swan_sync/communications/services/local_database.dart';
import 'package:swan_sync/communications/util/fallback/fallback.dart';
import 'package:swan_sync/communications/services/api.dart';
import 'package:swan_sync/data/i_syncable.dart';

import 'package:hive_flutter/hive_flutter.dart';

abstract class SwanSync {
  static final SyncController syncController = SyncController();
  static final Api api = Api();
  static LocalDatabase get database => syncController.database;

  /// List of registered adapter-prototype pairs
  static final List<({TypeAdapter adapter, ISyncable prototype})> registeredTypes = [];

  /// List of registered TypeAdapters for Hive
  static List<TypeAdapter> get adapters => registeredTypes.map((e) => e.adapter).toList();

  /// List of registered ISyncable prototypes for dynamic model creation
  static List<ISyncable> get prototypes => registeredTypes.map((e) => e.prototype).toList();

  /// List of registered table names for SWAN Sync
  static List<String> get tableNames => registeredTypes.map((e) => e.prototype.tableName).toList();

  static bool _hasInit = false;

  /// Initialize SWAN Sync with the provided list of TypeAdapters and ISyncable prototypes.
  /// The adapters are used for Hive storage, while the prototypes are used for dynamic model creation and server communication.
  ///
  /// The [types] parameter is a list of records containing a TypeAdapter and its corresponding ISyncable prototype
  static Future<void> initialize({
    required List<({TypeAdapter adapter, ISyncable prototype})> types,
    required String path,
  }) async {
    registeredTypes.addAll(types);
    // init hive
    await database.initialize();
    // init adapters and open boxes
    if (!_hasInit) {
      for (var (adapter: _, prototype: prototype) in types) {
        print('opening box for ${prototype.tableName}; ${prototype.runtimeType}');
        if (!Hive.isBoxOpen(prototype.tableName))
          await Hive.openBox<Map<dynamic, dynamic>>(prototype.tableName, path: path);
      }
      print('init done');
      _hasInit = true;
    }

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
