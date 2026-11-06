import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/item.dart';
import '../models/sync_operation.dart';
import '../models/community_price.dart';
import 'utils.dart';
import 'default_supermarkets.dart';

class DatabaseHelper {
  static const _databaseVersion = 4;
  static String _currentDatabaseName = "carrin_database_guest.db";

  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static String get currentDatabaseName => _currentDatabaseName;

  static Future<String> getCurrentDatabasePath() async {
    final databasesPath = await getDatabasesPath();
    return join(databasesPath, _currentDatabaseName);
  }

  static Database? _database;

  static void changeUser(String? email) {
    if (email == null || email.trim().isEmpty) {
      _currentDatabaseName = "carrin_database_guest.db";
    } else {
      final safeEmail = email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      _currentDatabaseName = "carrin_database_$safeEmail.db";
    }
    // Synchronously null _database first so the next access opens the correct DB.
    // Then close the old reference in the background.
    final oldDb = _database;
    _database = null;
    if (oldDb != null) {
      oldDb.close().catchError((_) {});
    }
  }

  static Future<void> closeDatabase() async {
    if (_database != null) {
      try {
        await _database!.close().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () {
            debugPrint('⚠️ DatabaseHelper: Fechamento do banco de dados expirou (timeout).');
          },
        );
      } catch (e) {
        // Ignora erros ao fechar
      }
      _database = null;
    }
  }

  static Future<void> deleteUserDatabase(String email) async {
    final safeEmail = email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final dbName = "carrin_database_$safeEmail.db";
    
    // Se for o banco ativo, fecha primeiro
    if (_currentDatabaseName == dbName) {
      await closeDatabase();
    }
    
    try {
      final databasesPath = await getDatabasesPath();
      final path = join(databasesPath, dbName);
      
      debugPrint('🗑️ DatabaseHelper: Iniciando exclusão direta dos arquivos do banco de dados: $dbName');
      
      // Deleta os arquivos diretamente via File (dart:io) sem usar o deleteDatabase do sqflite.
      // Isso é 100% livre de deadlock/travamentos porque não bloqueia na thread nativa do SQLite/sqflite.
      final fileExtensions = ['', '-journal', '-wal', '-shm'];
      for (final ext in fileExtensions) {
        try {
          final file = File('$path$ext');
          if (await file.exists()) {
            await file.delete();
            debugPrint('🗑️ DatabaseHelper: Arquivo deletado com sucesso: $path$ext');
          }
        } catch (fileErr) {
          debugPrint('⚠️ DatabaseHelper: Erro ao deletar arquivo $path$ext via File: $fileErr');
        }
      }
    } catch (e) {
      debugPrint('⚠️ DatabaseHelper: Erro geral ao deletar banco de dados: $e');
    }
  }

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), _currentDatabaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onConfigure(Database db) async {
    await db.execute("PRAGMA foreign_keys = ON");
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute("ALTER TABLE months ADD COLUMN is_finalized INTEGER NOT NULL DEFAULT 0;");
      } catch (e) {
        // Ignora se a coluna já existir por algum motivo
      }
    }
    if (oldVersion < 3) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS supermarkets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            latitude REAL,
            longitude REAL,
            radius_meters REAL NOT NULL DEFAULT 150.0,
            icon TEXT DEFAULT 'store',
            color_hex TEXT DEFAULT '#1E88E5',
            created_at TEXT
          );
        ''');
      } catch (e) {
        debugPrint('Aviso ao criar tabela supermarkets no upgrade: $e');
      }
      try {
        await db.execute("ALTER TABLE items ADD COLUMN supermarket TEXT;");
      } catch (_) {}
      try {
        await db.execute("ALTER TABLE months ADD COLUMN purpose TEXT NOT NULL DEFAULT 'geral';");
      } catch (_) {}
      try {
        await db.execute("ALTER TABLE months ADD COLUMN category_caps TEXT;");
      } catch (_) {}
      try {
        await db.execute("ALTER TABLE months ADD COLUMN workspace TEXT NOT NULL DEFAULT 'personal';");
      } catch (_) {}
    }
    if (oldVersion < 4) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS community_prices_cache (
            id TEXT PRIMARY KEY,
            product_name TEXT NOT NULL,
            category TEXT,
            unit TEXT,
            price REAL NOT NULL,
            supermarket_name TEXT NOT NULL,
            latitude REAL,
            longitude REAL,
            submitted_by TEXT,
            verified_receipt INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
          );
        ''');
      } catch (e) {
        debugPrint('Aviso ao criar tabela community_prices_cache no upgrade: $e');
      }
    }
  }

  Future _onCreate(Database db, int version) async {
    // Tabela de Meses (Carrinhos)
    await db.execute('''
      CREATE TABLE months (
        title TEXT PRIMARY KEY,
        budget REAL NOT NULL DEFAULT 0.0,
        total REAL NOT NULL DEFAULT 0.0,
        balance REAL NOT NULL DEFAULT 0.0,
        totalItems REAL NOT NULL DEFAULT 0.0,
        boughtItems REAL NOT NULL DEFAULT 0.0,
        is_finalized INTEGER NOT NULL DEFAULT 0,
        purpose TEXT NOT NULL DEFAULT 'geral',
        category_caps TEXT,
        workspace TEXT NOT NULL DEFAULT 'personal'
      )
    ''');

    // Tabela de Itens da Lista
    await db.execute('''
      CREATE TABLE items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        month_title TEXT NOT NULL,
        index_in_sheet INTEGER,
        name TEXT NOT NULL,
        quantity REAL NOT NULL DEFAULT 0.0,
        unit_price REAL NOT NULL DEFAULT 0.0,
        is_kg INTEGER NOT NULL DEFAULT 0,
        category TEXT NOT NULL DEFAULT 'Outros',
        is_bought INTEGER NOT NULL DEFAULT 0,
        barcode TEXT,
        supermarket TEXT,
        FOREIGN KEY (month_title) REFERENCES months (title) ON DELETE CASCADE
      )
    ''');

    // Tabela da Fila de Sincronização
    await db.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        month TEXT NOT NULL,
        payload TEXT NOT NULL
      )
    ''');

    // Tabela de Mercados Locais
    await db.execute('''
      CREATE TABLE supermarkets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        latitude REAL,
        longitude REAL,
        radius_meters REAL NOT NULL DEFAULT 150.0,
        icon TEXT DEFAULT 'store',
        color_hex TEXT DEFAULT '#1E88E5',
        created_at TEXT
      )
    ''');

    // Tabela de Preços Compartilhados da Comunidade (Cache Local)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS community_prices_cache (
        id TEXT PRIMARY KEY,
        product_name TEXT NOT NULL,
        category TEXT,
        unit TEXT,
        price REAL NOT NULL,
        supermarket_name TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        submitted_by TEXT,
        verified_receipt INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
  }

  // --- Operações de meses ---
  Future<List<String>> getMonthsList() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('months', columns: ['title'], orderBy: 'rowid ASC');
    return maps.map((m) => m['title'] as String).toList();
  }

  Future<void> saveMonthsList(List<String> months) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var month in months) {
        batch.insert(
          'months',
          {
            'title': month,
            'budget': 0.0,
            'total': 0.0,
            'balance': 0.0,
            'totalItems': 0.0,
            'boughtItems': 0.0,
            'is_finalized': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> insertMonth(
    String title, {
    double budget = 0.0,
    double total = 0.0,
    double balance = 0.0,
    double totalItems = 0.0,
    double boughtItems = 0.0,
    int isFinalized = 0,
    String purpose = 'geral',
    String workspace = 'personal',
  }) async {
    final db = await database;
    // Use IGNORE to prevent ON DELETE CASCADE from deleting items when month already exists
    final rowsAffected = await db.insert(
      'months',
      {
        'title': title,
        'budget': budget,
        'total': total,
        'balance': balance,
        'totalItems': totalItems,
        'boughtItems': boughtItems,
        'is_finalized': isFinalized,
        'purpose': purpose,
        'workspace': workspace,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // If month already existed (insert was ignored), update its values
    if (rowsAffected == 0) {
      await db.update(
        'months',
        {
          'budget': budget,
          'total': total,
          'balance': balance,
          'totalItems': totalItems,
          'boughtItems': boughtItems,
          'is_finalized': isFinalized,
        },
        where: 'title = ?',
        whereArgs: [title],
      );
    }
  }

  Future<void> renameMonth(String oldTitle, String newTitle) async {
    final db = await database;
    await db.transaction((txn) async {
      final List<Map<String, dynamic>> existing = await txn.query(
        'months',
        where: 'title = ?',
        whereArgs: [oldTitle],
      );
      if (existing.isNotEmpty) {
        final oldMonthData = Map<String, dynamic>.from(existing.first);
        oldMonthData['title'] = newTitle;
        await txn.insert('months', oldMonthData, conflictAlgorithm: ConflictAlgorithm.replace);
        
        await txn.update(
          'items',
          {'month_title': newTitle},
          where: 'month_title = ?',
          whereArgs: [oldTitle],
        );
        
        await txn.delete('months', where: 'title = ?', whereArgs: [oldTitle]);
      }
    });
  }

  Future<void> deleteMonth(String title) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('items', where: 'month_title = ?', whereArgs: [title]);
      await txn.delete('months', where: 'title = ?', whereArgs: [title]);
    });
  }

  Future<void> updateMonthSummary(String title, Map<String, double> summary) async {
    final db = await database;
    // Use UPDATE to avoid DELETE CASCADE that INSERT...REPLACE triggers
    final rowsAffected = await db.update(
      'months',
      {
        'budget': summary['budget'] ?? 0.0,
        'total': summary['total'] ?? 0.0,
        'balance': summary['balance'] ?? 0.0,
        'totalItems': summary['totalItems'] ?? 0.0,
        'boughtItems': summary['boughtItems'] ?? 0.0,
        'is_finalized': (summary['isFinalized'] ?? 0.0) == 1.0 ? 1 : 0,
      },
      where: 'title = ?',
      whereArgs: [title],
    );
    // If the month doesn't exist yet, insert it
    if (rowsAffected == 0) {
      await db.insert(
        'months',
        {
          'title': title,
          'budget': summary['budget'] ?? 0.0,
          'total': summary['total'] ?? 0.0,
          'balance': summary['balance'] ?? 0.0,
          'totalItems': summary['totalItems'] ?? 0.0,
          'boughtItems': summary['boughtItems'] ?? 0.0,
          'is_finalized': (summary['isFinalized'] ?? 0.0) == 1.0 ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<Map<String, Map<String, double>>> getMonthsSummaries() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('months', orderBy: 'rowid ASC');
    final Map<String, Map<String, double>> result = {};
    for (var row in maps) {
      result[row['title'] as String] = {
        'budget': (row['budget'] as num).toDouble(),
        'total': (row['total'] as num).toDouble(),
        'balance': (row['balance'] as num).toDouble(),
        'totalItems': (row['totalItems'] as num).toDouble(),
        'boughtItems': (row['boughtItems'] as num).toDouble(),
        'isFinalized': ((row['is_finalized'] ?? 0) as num).toDouble(),
      };
    }
    return result;
  }

  /// Recalcula e sincroniza o resumo dos meses locais a partir dos itens salvos no banco SQLite.
  /// Garante que se a planilha na nuvem enviou zeros ou erros de fórmula, o banco local se auto-recupera.
  Future<void> recalculateAllMonthSummaries() async {
    final db = await database;
    final months = await db.query('months');
    for (final m in months) {
      final title = (m['title'] as String? ?? '').trim();
      if (title.isEmpty) continue;
      final budget = (m['budget'] as num?)?.toDouble() ?? 0.0;
      final monthItems = await db.query('items', where: 'month_title = ?', whereArgs: [title]);
      if (monthItems.isNotEmpty) {
        double total = 0.0;
        int bought = 0;
        for (final it in monthItems) {
          final q = (it['quantity'] as num?)?.toDouble() ?? 0.0;
          final p = (it['unit_price'] as num?)?.toDouble() ?? 0.0;
          final isB = it['is_bought'] == 1;
          if (isB) {
            total += q * p;
            bought++;
          }
        }
        await db.update(
          'months',
          {
            'total': total,
            'balance': budget - total,
            'totalItems': monthItems.length.toDouble(),
            'boughtItems': bought.toDouble(),
          },
          where: 'title = ?',
          whereArgs: [title],
        );
      }
    }
  }

  // --- Operações de itens ---
  Future<List<Item>> getItems(String monthTitle) async {
    final db = await database;
    final cleanTitle = monthTitle.trim();
    final normTitle = Utils.normalize(cleanTitle);

    debugPrint('🔍 DB.getItems: db="$_currentDatabaseName", query month_title="$cleanTitle"');

    // 1. Tenta correspondência exata
    List<Map<String, dynamic>> maps = await db.query(
      'items',
      where: 'month_title = ?',
      whereArgs: [cleanTitle],
      orderBy: 'index_in_sheet ASC',
    );

    // 2. Se vazio, tenta busca case-insensitive e sem espaços extras
    if (maps.isEmpty) {
      maps = await db.query(
        'items',
        where: 'TRIM(LOWER(month_title)) = ?',
        whereArgs: [cleanTitle.toLowerCase()],
        orderBy: 'index_in_sheet ASC',
      );
    }

    // 3. Se ainda vazio, busca por normalização (ignora acentos)
    if (maps.isEmpty) {
      final allRows = await db.query('items', orderBy: 'index_in_sheet ASC');
      final matched = allRows.where((row) {
        final mTitle = (row['month_title'] as String? ?? '').trim();
        final norm = Utils.normalize(mTitle);
        return norm == normTitle || norm.startsWith(normTitle) || normTitle.startsWith(norm);
      }).toList();
      if (matched.isNotEmpty) {
        maps = matched;
        debugPrint('🔍 DB.getItems: Encontrados ${maps.length} itens por normalização para "$cleanTitle"');
      }
    }

    // 4. Se ainda vazio, busca em outros arquivos de banco locais (ex: carrin_database_guest.db)
    if (maps.isEmpty) {
      try {
        final databasesPath = await getDatabasesPath();
        final dir = Directory(databasesPath);
        if (await dir.exists()) {
          final dbFiles = dir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.db') && !f.path.endsWith(_currentDatabaseName),
          );
          for (var otherFile in dbFiles) {
            try {
              final otherDb = await openDatabase(otherFile.path);
              var otherMaps = await otherDb.query(
                'items',
                where: 'month_title = ?',
                whereArgs: [cleanTitle],
                orderBy: 'index_in_sheet ASC',
              );
              if (otherMaps.isEmpty) {
                otherMaps = await otherDb.query(
                  'items',
                  where: 'TRIM(LOWER(month_title)) = ?',
                  whereArgs: [cleanTitle.toLowerCase()],
                  orderBy: 'index_in_sheet ASC',
                );
              }
              if (otherMaps.isEmpty) {
                final otherRows = await otherDb.query('items', orderBy: 'index_in_sheet ASC');
                otherMaps = otherRows.where((row) {
                  final mTitle = (row['month_title'] as String? ?? '').trim();
                  final norm = Utils.normalize(mTitle);
                  return norm == normTitle || norm.startsWith(normTitle) || normTitle.startsWith(norm);
                }).toList();
              }

              if (otherMaps.isNotEmpty) {
                debugPrint('🔍 DB.getItems: Recuperados ${otherMaps.length} itens do banco alternativo "${basename(otherFile.path)}" para "$cleanTitle"');
                maps = otherMaps;

                // Restaura permanentemente no banco ativo
                final recoveredItems = otherMaps.map((map) {
                  return Item(
                    index: map['index_in_sheet'] as int?,
                    name: (map['name'] as String?) ?? '',
                    quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
                    unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0.0,
                    isKg: map['is_kg'] == 1,
                    category: (map['category'] as String?) ?? 'Outros',
                    isBought: map['is_bought'] == 1,
                    barcode: map['barcode'] as String?,
                    supermarket: map['supermarket'] as String?,
                  );
                }).toList();
                await saveItems(cleanTitle, recoveredItems);
                await otherDb.close();
                break;
              }
              await otherDb.close();
            } catch (err) {
              debugPrint('Aviso ao consultar banco alternativo ${otherFile.path}: $err');
            }
          }
        }
      } catch (e) {
        debugPrint('Erro ao varrer bancos alternativos: $e');
      }
    }

    debugPrint('🔍 DB.getItems: retornou ${maps.length} registros para "$cleanTitle"');
    if (maps.isEmpty) {
      final allMonths = await db.rawQuery('SELECT DISTINCT month_title FROM items');
      debugPrint('🔍 DB.getItems: month_titles existentes na tabela items: ${allMonths.map((m) => m['month_title']).toList()}');
    }
    return maps.map((map) {
      return Item(
        index: map['index_in_sheet'] as int?,
        name: (map['name'] as String?) ?? '',
        quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
        unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0.0,
        isKg: map['is_kg'] == 1,
        category: (map['category'] as String?) ?? 'Outros',
        isBought: map['is_bought'] == 1,
        barcode: map['barcode'] as String?,
        supermarket: map['supermarket'] as String?,
      );
    }).toList();
  }

  Future<void> saveItems(String monthTitle, List<Item> items) async {
    final db = await database;
    double calcTotal = 0.0;
    int calcBought = 0;
    for (final it in items) {
      if (it.isBought) {
        calcTotal += it.totalPrice;
        calcBought++;
      }
    }
    await db.transaction((txn) async {
      await txn.insert(
        'months',
        {
          'title': monthTitle,
          'budget': 0.0,
          'total': calcTotal,
          'balance': -calcTotal,
          'totalItems': items.length.toDouble(),
          'boughtItems': calcBought.toDouble(),
          'is_finalized': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final monthRows = await txn.query('months', columns: ['budget'], where: 'title = ?', whereArgs: [monthTitle]);
      final existingBudget = monthRows.isNotEmpty ? ((monthRows.first['budget'] as num?)?.toDouble() ?? 0.0) : 0.0;
      await txn.update(
        'months',
        {
          'total': calcTotal,
          'balance': existingBudget - calcTotal,
          'totalItems': items.length.toDouble(),
          'boughtItems': calcBought.toDouble(),
        },
        where: 'title = ?',
        whereArgs: [monthTitle],
      );

      await txn.delete('items', where: 'month_title = ?', whereArgs: [monthTitle]);

      final batch = txn.batch();
      for (var item in items) {
        batch.insert('items', {
          'month_title': monthTitle,
          'index_in_sheet': item.index,
          'name': item.name,
          'quantity': item.quantity,
          'unit_price': item.unitPrice,
          'is_kg': item.isKg ? 1 : 0,
          'category': item.category,
          'is_bought': item.isBought ? 1 : 0,
          'barcode': item.barcode,
          'supermarket': item.supermarket,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// Retorna o histórico consolidado de preços e barcodes de todos os itens cadastrados localmente
  Future<Map<String, List<Map<String, dynamic>>>> getAllPriceHistory() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'items',
      columns: ['month_title', 'name', 'unit_price', 'category', 'barcode', 'supermarket'],
      where: "name IS NOT NULL AND TRIM(name) != '' AND (unit_price > 0 OR (barcode IS NOT NULL AND TRIM(barcode) != ''))",
      orderBy: 'id ASC',
    );

    final Map<String, List<Map<String, dynamic>>> history = {};
    for (var row in maps) {
      final rawName = (row['name'] as String? ?? '').trim();
      if (rawName.isEmpty) continue;
      final normalized = Utils.normalize(rawName);
      final month = row['month_title'] as String? ?? '';
      final price = (row['unit_price'] as num?)?.toDouble() ?? 0.0;
      final rawBarcode = row['barcode'] as String? ?? '';
      final barcode = Item.parseBarcode(rawBarcode) ?? rawBarcode.trim();
      final category = row['category'] as String? ?? 'Outros';
      final supermarket = row['supermarket'] as String?;

      final list = history.putIfAbsent(normalized, () => []);
      final existingIdx = list.indexWhere((e) => e['month'] == month);
      final entryData = {
        'name': rawName,
        'month': month,
        'price': price,
        'category': category,
        'barcode': barcode,
        'supermarket': supermarket,
      };
      if (existingIdx != -1) {
        if ((entryData['barcode'] as String).isEmpty && (list[existingIdx]['barcode'] as String? ?? '').isNotEmpty) {
          entryData['barcode'] = list[existingIdx]['barcode'];
        }
        if (entryData['price'] == 0 && (list[existingIdx]['price'] as num? ?? 0) > 0) {
          entryData['price'] = list[existingIdx]['price'];
        }
        if (entryData['supermarket'] == null && list[existingIdx]['supermarket'] != null) {
          entryData['supermarket'] = list[existingIdx]['supermarket'];
        }
        list[existingIdx] = entryData;
      } else {
        list.add(entryData);
      }
    }
    return history;
  }

  // --- Operações de fila de sincronização ---
  Future<List<SyncOperation>> getSyncQueue() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('sync_queue');
    return maps.map((map) {
      return SyncOperation(
        id: map['id'],
        type: map['type'],
        month: map['month'],
        payload: jsonDecode(map['payload']),
      );
    }).toList();
  }

  Future<void> saveSyncQueue(List<SyncOperation> queue) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('sync_queue');
      final batch = txn.batch();
      for (var op in queue) {
        batch.insert('sync_queue', {
          'id': op.id,
          'type': op.type,
          'month': op.month,
          'payload': jsonEncode(op.payload),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  // --- Operações de Mercados Locais (Supermarkets) ---
  Future<List<Map<String, dynamic>>> getSupermarkets() async {
    final db = await database;
    try {
      return await db.query(
        'supermarkets',
        where: "LOWER(name) NOT IN ('supermercado local', 'supermercado')",
        orderBy: 'name ASC',
      );
    } catch (e) {
      debugPrint('Aviso ao consultar supermercados: $e');
      return [];
    }
  }

  Future<int> saveSupermarket({
    required String name,
    double? latitude,
    double? longitude,
    double radiusMeters = 150.0,
    String icon = 'store',
    String colorHex = '#1E88E5',
  }) async {
    final db = await database;
    final cleanName = name.trim();
    if (cleanName.isEmpty) return -1;

    final existing = await db.query(
      'supermarkets',
      where: 'LOWER(name) = ?',
      whereArgs: [cleanName.toLowerCase()],
    );

    final values = {
      'name': cleanName,
      'latitude': latitude,
      'longitude': longitude,
      'radius_meters': radiusMeters,
      'icon': icon,
      'color_hex': colorHex,
      'created_at': DateTime.now().toIso8601String(),
    };

    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update('supermarkets', values, where: 'id = ?', whereArgs: [id]);
      return id;
    } else {
      return await db.insert('supermarkets', values);
    }
  }

  Future<void> deleteSupermarket(int id) async {
    final db = await database;
    await db.delete('supermarkets', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSupermarketByName(String name) async {
    final db = await database;
    await db.delete('supermarkets', where: 'LOWER(name) = ?', whereArgs: [name.trim().toLowerCase()]);
  }

  // --- Operações de Metadados de Meses (Purpose, Category Caps, Workspace) ---
  Future<Map<String, dynamic>?> getMonthDetails(String title) async {
    final db = await database;
    final maps = await db.query('months', where: 'title = ?', whereArgs: [title]);
    if (maps.isNotEmpty) {
      return maps.first;
    }
    return null;
  }

  Future<void> updateMonthMetadata(
    String title, {
    String? purpose,
    String? categoryCaps,
    String? workspace,
  }) async {
    final db = await database;
    final Map<String, dynamic> values = {};
    if (purpose != null) values['purpose'] = purpose;
    if (categoryCaps != null) values['category_caps'] = categoryCaps;
    if (workspace != null) values['workspace'] = workspace;

    if (values.isNotEmpty) {
      await db.update(
        'months',
        values,
        where: 'title = ?',
        whereArgs: [title],
      );
    }
  }

  static bool isDummySheetName(String title) {
    final lower = title.trim().toLowerCase();
    return lower.isEmpty ||
        lower == 'página1' ||
        lower == 'página 1' ||
        lower == 'pagina1' ||
        lower == 'pagina 1' ||
        lower == 'sheet1' ||
        lower == 'sheet 1';
  }

  Future<List<String>> getMonthsByWorkspace(String workspace) async {
    final db = await database;
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        'months',
        columns: ['title'],
        where: workspace == 'personal'
            ? "(workspace = ? OR workspace IS NULL OR TRIM(workspace) = '')"
            : 'workspace = ?',
        whereArgs: [workspace],
        orderBy: 'rowid ASC',
      );
      return maps
          .map((m) => m['title'] as String)
          .where((t) => !isDummySheetName(t))
          .toList();
    } catch (_) {
      final list = await getMonthsList();
      return list.where((t) => !isDummySheetName(t)).toList();
    }
  }

  // --- Operações de Preços da Comunidade (Cache Local) ---

  Future<void> saveCommunityPrice(CommunityPrice price) async {
    final db = await database;
    try {
      await db.insert(
        'community_prices_cache',
        price.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('Erro ao salvar preço da comunidade no SQLite: $e');
    }
  }

  Future<void> saveCommunityPrices(List<CommunityPrice> prices) async {
    final db = await database;
    try {
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var p in prices) {
          batch.insert(
            'community_prices_cache',
            p.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      debugPrint('Erro ao salvar lote de preços da comunidade no SQLite: $e');
    }
  }

  Future<List<CommunityPrice>> getCachedCommunityPrices({
    String? query, 
    String? supermarket,
    double? userLat,
    double? userLng,
  }) async {
    final db = await database;
    try {
      final List<String> conditions = [];
      final List<dynamic> whereArgs = [];

      if (query != null && query.trim().isNotEmpty) {
        conditions.add('product_name LIKE ?');
        whereArgs.add('%${query.trim()}%');
      }

      if (supermarket != null && supermarket.trim().isNotEmpty) {
        conditions.add('supermarket_name = ?');
        whereArgs.add(supermarket.trim());
      }

      conditions.add("LOWER(supermarket_name) NOT IN ('carrefour', 'atacadão', 'atacadao', 'assaí atacadista', 'assai atacadista')");
      conditions.add("submitted_by NOT LIKE 'Teste%'");
      conditions.add("submitted_by != 'Comunidade CARRIN'");
      conditions.add("id NOT LIKE 'seed_%'");

      final where = conditions.join(' AND ');

      final List<Map<String, dynamic>> maps = await db.query(
        'community_prices_cache',
        where: where,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'created_at DESC',
        limit: 500,
      );

      // Deduplica mantendo apenas o registro mais recente por (produto + mercado)
      final List<CommunityPrice> deduped = [];
      final Set<String> seenProductMarkets = {};

      for (var m in maps) {
        final p = CommunityPrice.fromMap(m, userLat: userLat, userLng: userLng);
        final normProduct = p.productName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final normMarket = p.supermarketName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final key = '$normProduct|$normMarket';

        // Como a consulta já é 'ORDER BY created_at DESC', o primeiro encontrado é o mais recente
        if (seenProductMarkets.add(key)) {
          deduped.add(p);
        }
      }

      return deduped;
    } catch (e) {
      debugPrint('Erro ao carregar preços da comunidade do SQLite: $e');
      return [];
    }
  }

  /// Extrai a melhor estimativa de data para um carrinho/mês baseado no seu título
  /// Ex: "Outubro 2026" -> 2026-10-01
  /// Ex: "15/10/2026" ou "15-10-2026" -> 2026-10-15
  static DateTime parseDateFromMonthTitle(String? monthTitle, {DateTime? fallbackDate}) {
    if (monthTitle == null || monthTitle.trim().isEmpty) {
      return fallbackDate ?? DateTime.now();
    }
    final raw = monthTitle.trim();

    // 1. Tenta formato dd/MM/yyyy ou dd-MM-yyyy
    final dmyMatch = RegExp(r'(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})').firstMatch(raw);
    if (dmyMatch != null) {
      final day = int.tryParse(dmyMatch.group(1)!) ?? 1;
      final month = int.tryParse(dmyMatch.group(2)!) ?? 1;
      final year = int.tryParse(dmyMatch.group(3)!) ?? 2026;
      return DateTime(year, month, day.clamp(1, 28), 12, 0, 0);
    }

    // 2. Tenta formato MM/yyyy ou MM-yyyy
    final myMatch = RegExp(r'(\d{1,2})[\/\-](\d{4})').firstMatch(raw);
    if (myMatch != null) {
      final month = int.tryParse(myMatch.group(1)!) ?? 1;
      final year = int.tryParse(myMatch.group(2)!) ?? 2026;
      return DateTime(year, month, 1, 12, 0, 0);
    }

    // 3. Tenta meses em português com ano (ex: "Outubro 2026", "Out 2026", "Outubro/26")
    final norm = Utils.normalize(raw).toLowerCase();
    int? detectedMonth;
    final monthsMap = {
      'janeiro': 1, 'jan': 1,
      'fevereiro': 2, 'fev': 2,
      'marco': 3, 'mar': 3,
      'abril': 4, 'abr': 4,
      'maio': 5, 'mai': 5,
      'junho': 6, 'jun': 6,
      'julho': 7, 'jul': 7,
      'agosto': 8, 'ago': 8,
      'setembro': 9, 'set': 9,
      'outubro': 10, 'out': 10,
      'novembro': 11, 'nov': 11,
      'dezembro': 12, 'dez': 12,
    };

    for (final entry in monthsMap.entries) {
      if (norm.contains(entry.key)) {
        detectedMonth = entry.value;
        break;
      }
    }

    if (detectedMonth != null) {
      final yearMatch = RegExp(r'(20\d\d)').firstMatch(raw);
      int year = DateTime.now().year;
      if (yearMatch != null) {
        year = int.tryParse(yearMatch.group(1)!) ?? year;
      } else {
        final shortYearMatch = RegExp(r'[\s\/\-](\d{2})(?!\d)').firstMatch(raw);
        if (shortYearMatch != null) {
          year = (int.tryParse(shortYearMatch.group(1)!) ?? 26) + 2000;
        }
      }
      return DateTime(year, detectedMonth, 1, 12, 0, 0);
    }

    return fallbackDate ?? DateTime.now();
  }

  /// Remove duplicatas físicas do banco mantendo apenas o registro mais recente/relevante de cada produto por mercado
  Future<int> deduplicateCommunityPricesCache() async {
    final db = await database;
    try {
      try {
        final deleted = await db.rawDelete('''
          DELETE FROM community_prices_cache
          WHERE id NOT IN (
            SELECT id
            FROM (
              SELECT id,
                     ROW_NUMBER() OVER (
                       PARTITION BY LOWER(TRIM(product_name)), LOWER(TRIM(supermarket_name))
                       ORDER BY verified_receipt DESC, created_at DESC, rowid DESC
                     ) as rn
              FROM community_prices_cache
            )
            WHERE rn = 1
          )
        ''');
        return deleted;
      } catch (_) {
        // Fallback para SQLite legado
        return await db.rawDelete('''
          DELETE FROM community_prices_cache
          WHERE rowid NOT IN (
            SELECT MAX(rowid)
            FROM community_prices_cache
            GROUP BY LOWER(TRIM(product_name)), LOWER(TRIM(supermarket_name))
          )
        ''');
      }
    } catch (e) {
      debugPrint('Aviso ao deduplicar cache da comunidade no SQLite: $e');
      return 0;
    }
  }

  /// Corrige datas de preços locais existentes gerados com timestamp equivocado de "hoje"
  Future<void> fixExistingLocalPricesDates() async {
    final db = await database;
    try {
      final userItems = await getAllUserPurchasedProducts();
      if (userItems.isEmpty) return;

      for (var row in userItems) {
        final name = (row['name'] as String? ?? '').trim();
        final monthTitle = row['month_title'] as String?;
        if (name.isEmpty || monthTitle == null || monthTitle.trim().isEmpty) continue;

        final realDate = parseDateFromMonthTitle(monthTitle);
        await db.update(
          'community_prices_cache',
          {'created_at': realDate.toIso8601String()},
          where: "id LIKE 'local_%' AND LOWER(TRIM(product_name)) = ?",
          whereArgs: [name.toLowerCase().trim()],
        );
      }
    } catch (e) {
      debugPrint('Aviso ao recalibrar datas locais: $e');
    }
  }

  /// Popula o cache local da comunidade a partir das compras do próprio usuário,
  /// respeitando a data real de criação da lista/mês e sem sobrescrever preços existentes.
  Future<int> seedCommunityPricesFromUserPurchases() async {
    final db = await database;
    try {
      final userItems = await getAllUserPurchasedProducts();
      if (userItems.isEmpty) return 0;

      // 1. Obtém os produtos que já constam no cache para NÃO alterar suas datas
      final existingRows = await db.rawQuery(
        'SELECT LOWER(TRIM(product_name)) as p, LOWER(TRIM(supermarket_name)) as s FROM community_prices_cache'
      );
      final Set<String> existingInCache = {};
      for (final r in existingRows) {
        final p = (r['p'] as String? ?? '').trim();
        final s = (r['s'] as String? ?? '').trim();
        if (p.isNotEmpty) existingInCache.add('$p|$s');
      }

      int inserted = 0;
      await db.transaction((txn) async {
        final batch = txn.batch();
        final Set<String> seenLocalKeys = {};

        for (var row in userItems) {
          final name = (row['name'] as String? ?? '').trim();
          final price = (row['unit_price'] as num?)?.toDouble() ?? 0.0;
          if (name.isEmpty || price <= 0) continue;

          String market = (row['supermarket'] as String? ?? '').trim();
          if (market.isEmpty || market.toLowerCase() == 'supermercado local' || market.toLowerCase() == 'supermercado') {
            market = 'Supermercados Guanabara';
          }

          final normProduct = name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
          final normMarket = market.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
          final dedupeKey = '$normProduct|$normMarket';

          // Se já está no cache com data real ou já visto neste lote, preserva e não sobrescreve
          if (existingInCache.contains(dedupeKey) || !seenLocalKeys.add(dedupeKey)) {
            continue;
          }

          final match = DefaultSupermarketsData.findMatch(market);
          final mLat = match?.latitude ?? -22.89012;
          final mLng = match?.longitude ?? -43.11535;

          final monthTitle = row['month_title'] as String?;
          final itemDate = parseDateFromMonthTitle(monthTitle);

          final id = 'local_${normProduct}_$normMarket';
          batch.insert(
            'community_prices_cache',
            {
              'id': id,
              'product_name': name,
              'category': row['category'] as String? ?? 'Outros',
              'unit': row['is_kg'] == 1 ? 'kg' : 'un',
              'price': price,
              'supermarket_name': market,
              'latitude': mLat,
              'longitude': mLng,
              'submitted_by': 'Cliente CARRIN',
              'verified_receipt': 0,
              'created_at': itemDate.toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          inserted++;
        }
        await batch.commit(noResult: true);
      });
      await deduplicateCommunityPricesCache();
      return inserted;
    } catch (e) {
      debugPrint('Erro ao semear preços locais da comunidade: $e');
      return 0;
    }
  }

  /// Atribui supermercado padrão a itens que não possuem mercado definido ou possuem supermercado de teste
  Future<int> assignDefaultSupermarket(String defaultMarket) async {
    final db = await database;
    try {
      final count = await db.rawUpdate('''
        UPDATE items
        SET supermarket = ?
        WHERE supermarket IS NULL 
           OR TRIM(supermarket) = '' 
           OR LOWER(supermarket) = 'supermercado local'
           OR LOWER(supermarket) = 'supermercado'
      ''', [defaultMarket.trim()]);
      if (count > 0) {
        debugPrint('🛒 $count itens migrados para o supermercado "$defaultMarket"');
      }
      return count;
    } catch (e) {
      debugPrint('Erro ao atribuir supermercado padrão aos itens: $e');
      return 0;
    }
  }

  /// Garante que os supermercados padrão estejam sincronizados e calibrados no SQLite sem gargalo de inicialização
  Future<void> ensureDefaultSupermarkets() async {
    final db = await database;
    try {
      final existingRows = await db.query('supermarkets', columns: ['id', 'name']);
      final Map<String, int> existingByName = {};
      for (final row in existingRows) {
        final n = (row['name'] as String? ?? '').trim().toLowerCase();
        final id = row['id'] as int?;
        if (n.isNotEmpty && id != null) {
          existingByName[n] = id;
        }
      }

      final cachedMarketsRows = await db.rawQuery(
        'SELECT DISTINCT LOWER(supermarket_name) AS sname FROM community_prices_cache WHERE supermarket_name IS NOT NULL',
      );
      final Set<String> activeCachedMarketNames = {
        for (final r in cachedMarketsRows)
          if (r['sname'] is String) (r['sname'] as String).trim(),
      };

      final nowIso = DateTime.now().toIso8601String();
      const allCatalog = DefaultSupermarketsData.all;
      final int coreLimit = allCatalog.length < 160 ? allCatalog.length : 160;

      await db.transaction((txn) async {
        final batch = txn.batch();

        for (int i = 0; i < allCatalog.length; i++) {
          final s = allCatalog[i];
          final key = s.name.trim().toLowerCase();
          final existingId = existingByName[key];

          if (existingId != null) {
            batch.update(
              'supermarkets',
              {
                'latitude': s.latitude,
                'longitude': s.longitude,
                'radius_meters': s.radiusMeters,
                'color_hex': s.colorHex,
                'icon': s.icon,
              },
              where: 'id = ?',
              whereArgs: [existingId],
            );
          } else if (i < coreLimit) {
            batch.insert(
              'supermarkets',
              {
                'name': s.name.trim(),
                'latitude': s.latitude,
                'longitude': s.longitude,
                'radius_meters': s.radiusMeters,
                'icon': s.icon,
                'color_hex': s.colorHex,
                'created_at': nowIso,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }

          if (activeCachedMarketNames.contains(key)) {
            batch.update(
              'community_prices_cache',
              {
                'latitude': s.latitude,
                'longitude': s.longitude,
              },
              where: 'LOWER(supermarket_name) = ?',
              whereArgs: [key],
            );
          }
        }

        // Unifica qualquer supermercado legado 'Supermercados Guanabara' para 'Supermercados Guanabara - Niterói'
        batch.rawUpdate('''
          UPDATE community_prices_cache
          SET supermarket_name = 'Supermercados Guanabara - Niterói'
          WHERE LOWER(supermarket_name) = 'supermercados guanabara'
        ''');
        batch.rawDelete('''
          DELETE FROM supermarkets
          WHERE LOWER(name) = 'supermercados guanabara'
        ''');

        await batch.commit(noResult: true);
      });

      debugPrint('📍 Catálogo de ${DefaultSupermarketsData.all.length} supermercados MWM ativo ($coreLimit base no SQLite)');
    } catch (e) {
      debugPrint('Erro ao assegurar mercados padrão: $e');
    }
  }

  /// Busca um supermercado pelo nome exato ou correspondência aproximada
  Future<Map<String, dynamic>?> findSupermarketByName(String name) async {
    final db = await database;
    try {
      final clean = name.trim().toLowerCase();
      if (clean.isEmpty) return null;

      // 1. Busca exata
      final exact = await db.query(
        'supermarkets',
        where: 'LOWER(name) = ?',
        whereArgs: [clean],
        limit: 1,
      );
      if (exact.isNotEmpty) return exact.first;

      // 2. Busca aproximada por LIKE
      final likeMatch = await db.query(
        'supermarkets',
        where: 'LOWER(name) LIKE ?',
        whereArgs: ['%$clean%'],
        limit: 1,
      );
      if (likeMatch.isNotEmpty) return likeMatch.first;

      return null;
    } catch (e) {
      debugPrint('Erro ao buscar supermercado por nome: $e');
      return null;
    }
  }

  /// Retorna todos os produtos registrados nas listas do usuário com preço > 0
  Future<List<Map<String, dynamic>>> getAllUserPurchasedProducts() async {
    final db = await database;
    try {
      final List<Map<String, dynamic>> results = await db.rawQuery('''
        SELECT 
          id,
          name, 
          unit_price, 
          is_kg, 
          category, 
          supermarket, 
          month_title
        FROM items
        WHERE unit_price > 0 
          AND name IS NOT NULL 
          AND TRIM(name) != ''
        ORDER BY id DESC
      ''');
      return results;
    } catch (e) {
      debugPrint('Erro ao obter produtos do usuário: $e');
      return [];
    }
  }

  Future<void> clearCommunityPrices() async {
    final db = await database;
    try {
      await db.delete('community_prices_cache');
    } catch (_) {}
  }

  Future<void> purgeSeedCommunityPrices() async {
    final db = await database;
    try {
      await db.delete(
        'community_prices_cache',
        where: "id LIKE 'seed_%' OR submitted_by = 'Comunidade CARRIN' OR submitted_by LIKE 'Teste%'",
      );
    } catch (_) {}
  }

  Future<void> cleanTestSupermarkets() async {
    final db = await database;
    try {
      await db.delete(
        'supermarkets',
        where: "LOWER(name) IN ('supermercado local', 'supermercado')",
      );
    } catch (_) {}
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('items');
      await txn.delete('months');
      await txn.delete('sync_queue');
      try {
        await txn.delete('supermarkets');
      } catch (_) {}
      try {
        await txn.delete('community_prices_cache');
      } catch (_) {}
    });
  }

  /// Salva um snapshot JSON de segurança de todas as listas e itens no SharedPreferences
  Future<void> saveLocalBackupSnapshot() async {
    try {
      final db = await database;
      final prefs = await SharedPreferences.getInstance();
      final monthRows = await db.query('months', orderBy: 'rowid ASC');
      if (monthRows.isEmpty) return;

      final deletedList = prefs.getStringList('explicitly_deleted_months') ?? const <String>[];
      final Set<String> explicitlyDeleted = deletedList.map((e) => e.trim().toLowerCase()).toSet();

      final Map<String, dynamic> snapshot = {};
      // Preserva backups anteriores de meses que ainda não estejam vazios nem deletados
      final existingRaw = prefs.getString('local_backup_carts_v1');
      if (existingRaw != null && existingRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(existingRaw);
          if (decoded is Map<String, dynamic>) {
            snapshot.addAll(decoded);
          }
        } catch (_) {}
      }
      snapshot.removeWhere((k, _) => explicitlyDeleted.contains(k.trim().toLowerCase()));

      for (final m in monthRows) {
        final title = (m['title'] as String? ?? '').trim();
        if (isDummySheetName(title) || explicitlyDeleted.contains(title.toLowerCase())) continue;
        final itemRows = await db.query(
          'items',
          where: 'month_title = ?',
          whereArgs: [title],
          orderBy: 'index_in_sheet ASC',
        );
        if (itemRows.isNotEmpty) {
          snapshot[title] = {
            'month': m,
            'items': itemRows,
            'updated_at': DateTime.now().toIso8601String(),
          };
        }
      }

      if (snapshot.isNotEmpty) {
        await prefs.setString('local_backup_carts_v1', jsonEncode(snapshot));
      }
    } catch (e) {
      debugPrint('Aviso ao salvar snapshot local de listas: $e');
    }
  }

  /// Auto-recupera e consolida listas/carrinhos e itens do usuário a partir de:
  /// 1. Itens órfãos no próprio banco SQLite
  /// 2. Outros arquivos .db locais (guest, offline, outras sessões)
  /// 3. Snapshot JSON local (`local_backup_carts_v1`)
  /// 4. Histórico de preços salvo em SharedPreferences (`cache_price_history_v2*`)
  /// 5. Cache local de compras do usuário (`community_prices_cache` com `local_%`)
  Future<void> recoverAndConsolidateUserData() async {
    try {
      final db = await database;
      final prefs = await SharedPreferences.getInstance();
      final deletedList = prefs.getStringList('explicitly_deleted_months') ?? const <String>[];
      final Set<String> explicitlyDeleted = deletedList.map((e) => e.trim().toLowerCase()).toSet();

      bool isDeleted(String title) => explicitlyDeleted.contains(title.trim().toLowerCase());

      // 1. Remove abas fantasmas ('Página1', 'Sheet1') vazias e listas explicitamente deletadas
      final allMonths = await db.query('months');
      for (final m in allMonths) {
        final t = (m['title'] as String? ?? '').trim();
        if (isDeleted(t)) {
          await db.delete('items', where: 'month_title = ?', whereArgs: [t]);
          await db.delete('months', where: 'title = ?', whereArgs: [t]);
          continue;
        }
        if (isDummySheetName(t)) {
          final c = Sqflite.firstIntValue(
                await db.rawQuery('SELECT COUNT(*) FROM items WHERE month_title = ?', [t]),
              ) ??
              0;
          if (c == 0) {
            await db.delete('months', where: 'title = ?', whereArgs: [t]);
          }
        }
      }

      // Purga também quaisquer itens órfãos pertencentes a listas explicitamente deletadas
      for (final del in explicitlyDeleted) {
        await db.delete('items', where: 'LOWER(TRIM(month_title)) = ?', whereArgs: [del]);
        await db.delete('months', where: 'LOWER(TRIM(title)) = ?', whereArgs: [del]);
      }

      // 2. Garante que qualquer month_title presente em `items` exista na tabela `months`
      final distinctItemMonths = await db.rawQuery('SELECT DISTINCT month_title FROM items');
      for (final row in distinctItemMonths) {
        final mTitle = (row['month_title'] as String? ?? '').trim();
        if (mTitle.isNotEmpty && !isDummySheetName(mTitle) && !isDeleted(mTitle)) {
          await db.insert(
            'months',
            {
              'title': mTitle,
              'budget': 0.0,
              'total': 0.0,
              'balance': 0.0,
              'totalItems': 0.0,
              'boughtItems': 0.0,
              'is_finalized': 0,
              'purpose': 'geral',
              'workspace': 'personal',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      // 3. Varre outros arquivos .db no diretório do aplicativo para resgatar listas/itens
      try {
        final databasesPath = await getDatabasesPath();
        final dir = Directory(databasesPath);
        if (await dir.exists()) {
          final dbFiles = dir.listSync().whereType<File>().where(
                (f) => f.path.endsWith('.db') && !f.path.endsWith(_currentDatabaseName),
              );
          for (final otherFile in dbFiles) {
            Database? otherDb;
            try {
              otherDb = await openDatabase(otherFile.path);
              final otherMonths = await otherDb.query('months');
              final otherItemMonths = await otherDb.rawQuery('SELECT DISTINCT month_title FROM items');

              final Set<String> candidateTitles = {
                for (final m in otherMonths) (m['title'] as String? ?? '').trim(),
                for (final r in otherItemMonths) (r['month_title'] as String? ?? '').trim(),
              };

              for (final title in candidateTitles) {
                if (title.isEmpty || isDummySheetName(title) || isDeleted(title)) continue;

                final currentItemsCount = Sqflite.firstIntValue(
                      await db.rawQuery('SELECT COUNT(*) FROM items WHERE month_title = ?', [title]),
                    ) ??
                    0;
                final otherItems = await otherDb.query(
                  'items',
                  where: 'month_title = ?',
                  whereArgs: [title],
                  orderBy: 'index_in_sheet ASC',
                );

                final monthRowList = otherMonths.where((m) => (m['title'] as String? ?? '').trim() == title).toList();
                final existingMonthInActive = await db.query('months', where: 'title = ?', whereArgs: [title]);

                if (existingMonthInActive.isEmpty && (otherItems.isNotEmpty || monthRowList.isNotEmpty)) {
                  final mData = monthRowList.isNotEmpty ? monthRowList.first : <String, dynamic>{};
                  await db.insert(
                    'months',
                    {
                      'title': title,
                      'budget': (mData['budget'] as num?)?.toDouble() ?? 0.0,
                      'total': (mData['total'] as num?)?.toDouble() ?? 0.0,
                      'balance': (mData['balance'] as num?)?.toDouble() ?? 0.0,
                      'totalItems': (mData['totalItems'] as num?)?.toDouble() ?? otherItems.length.toDouble(),
                      'boughtItems': (mData['boughtItems'] as num?)?.toDouble() ?? 0.0,
                      'is_finalized': (mData['is_finalized'] as int?) ?? 0,
                      'purpose': (mData['purpose'] as String?) ?? 'geral',
                      'category_caps': mData['category_caps'] as String?,
                      'workspace': (mData['workspace'] as String?) ?? 'personal',
                    },
                    conflictAlgorithm: ConflictAlgorithm.ignore,
                  );
                }

                if (otherItems.length > currentItemsCount) {
                  final recovered = otherItems.map((map) {
                    return Item(
                      index: map['index_in_sheet'] as int?,
                      name: (map['name'] as String?) ?? '',
                      quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
                      unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0.0,
                      isKg: map['is_kg'] == 1,
                      category: (map['category'] as String?) ?? 'Outros',
                      isBought: map['is_bought'] == 1,
                      barcode: map['barcode'] as String?,
                      supermarket: map['supermarket'] as String?,
                    );
                  }).toList();
                  await saveItems(title, recovered);
                  debugPrint('♻️ DatabaseHelper: Recuperados ${recovered.length} itens do mês "$title" de ${basename(otherFile.path)}');
                }
              }
            } catch (e) {
              debugPrint('Aviso ao inspecionar banco alternativo ${otherFile.path}: $e');
            } finally {
              try {
                await otherDb?.close();
              } catch (_) {}
            }
          }
        }
      } catch (e) {
        debugPrint('Aviso ao varrer bancos alternativos na recuperação: $e');
      }

      // 4. Restaura a partir do snapshot JSON (`local_backup_carts_v1`) caso algum mês tenha sido perdido
      try {
        final rawSnapshot = prefs.getString('local_backup_carts_v1');
        if (rawSnapshot != null && rawSnapshot.isNotEmpty) {
          final decoded = jsonDecode(rawSnapshot);
          if (decoded is Map<String, dynamic>) {
            for (final entry in decoded.entries) {
              final title = entry.key.trim();
              if (title.isEmpty || isDummySheetName(title) || isDeleted(title)) continue;
              final data = entry.value;
              if (data is! Map<String, dynamic>) continue;

              final currentCount = Sqflite.firstIntValue(
                    await db.rawQuery('SELECT COUNT(*) FROM items WHERE month_title = ?', [title]),
                  ) ??
                  0;
              final rawItems = data['items'];
              if (rawItems is List && rawItems.isNotEmpty && currentCount < rawItems.length) {
                final mData = data['month'] is Map<String, dynamic>
                    ? data['month'] as Map<String, dynamic>
                    : <String, dynamic>{};
                await db.insert(
                  'months',
                  {
                    'title': title,
                    'budget': (mData['budget'] as num?)?.toDouble() ?? 0.0,
                    'total': (mData['total'] as num?)?.toDouble() ?? 0.0,
                    'balance': (mData['balance'] as num?)?.toDouble() ?? 0.0,
                    'totalItems': rawItems.length.toDouble(),
                    'boughtItems': 0.0,
                    'is_finalized': (mData['is_finalized'] as int?) ?? 0,
                    'purpose': (mData['purpose'] as String?) ?? 'geral',
                    'workspace': (mData['workspace'] as String?) ?? 'personal',
                  },
                  conflictAlgorithm: ConflictAlgorithm.ignore,
                );

                final existingDbItems = await getItems(title);
                final existingNames = existingDbItems.map((e) => Utils.normalize(e.name)).toSet();

                final restoredItems = List<Item>.from(existingDbItems);
                int idx = restoredItems.isEmpty
                    ? 7
                    : (restoredItems.map((e) => e.index ?? 0).fold<int>(0, (a, b) => a > b ? a : b) + 1);

                for (final raw in rawItems) {
                  if (raw is Map) {
                    final name = (raw['name'] as String?) ?? '';
                    if (name.isEmpty || existingNames.contains(Utils.normalize(name))) {
                      continue;
                    }
                    restoredItems.add(Item(
                      index: (raw['index_in_sheet'] as int?) ?? idx++,
                      name: name,
                      quantity: (raw['quantity'] as num?)?.toDouble() ?? 1.0,
                      unitPrice: (raw['unit_price'] as num?)?.toDouble() ?? 0.0,
                      isKg: raw['is_kg'] == 1 || raw['is_kg'] == true,
                      category: (raw['category'] as String?) ?? 'Outros',
                      isBought: raw['is_bought'] == 1 || raw['is_bought'] == true,
                      barcode: raw['barcode'] as String?,
                      supermarket: raw['supermarket'] as String?,
                    ));
                  }
                }
                if (restoredItems.length > existingDbItems.length) {
                  await saveItems(title, restoredItems);
                  debugPrint('♻️ DatabaseHelper: Restaurados ${restoredItems.length - existingDbItems.length} itens do mês "$title" via local_backup_carts_v1');
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Aviso ao restaurar snapshot local: $e');
      }

      // 5. Reconstrói listas apagadas a partir do cache de histórico de preços (`cache_price_history_v2*`)
      try {
        final allKeys = prefs.getKeys();
        final historyKeys = allKeys.where((k) => k.startsWith('cache_price_history_v2')).toList();
        final Map<String, Map<String, Map<String, dynamic>>> itemsByMonth = {};

        for (final key in historyKeys) {
          final rawJson = prefs.getString(key);
          if (rawJson == null || rawJson.isEmpty) continue;
          try {
            final decoded = jsonDecode(rawJson);
            if (decoded is Map<String, dynamic>) {
              for (final historyEntry in decoded.entries) {
                final list = historyEntry.value;
                if (list is List) {
                  for (final itemEntry in list) {
                    if (itemEntry is Map) {
                      final month = (itemEntry['month'] as String? ?? '').trim();
                      final name = (itemEntry['name'] as String? ?? '').trim();
                      if (month.isEmpty || name.isEmpty || isDummySheetName(month) || isDeleted(month)) {
                        continue;
                      }
                      final normName = Utils.normalize(name);
                      final monthMap = itemsByMonth.putIfAbsent(month, () => {});
                      final price = (itemEntry['price'] as num?)?.toDouble() ?? 0.0;
                      final existing = monthMap[normName];
                      if (existing == null || (price > 0 && ((existing['price'] as num?)?.toDouble() ?? 0.0) == 0.0)) {
                        monthMap[normName] = {
                          'name': name,
                          'price': price,
                          'category': (itemEntry['category'] as String?) ?? 'Outros',
                          'barcode': itemEntry['barcode'] as String?,
                          'supermarket': itemEntry['supermarket'] as String?,
                        };
                      }
                    }
                  }
                }
              }
            }
          } catch (_) {}
        }

        // Recupera orçamento salvo em quick_summary se existir
        double savedQuickBudget = 0.0;
        String savedQuickMonth = '';
        for (final k in allKeys.where((k) => k.startsWith('quick_summary'))) {
          final rawQ = prefs.getString(k);
          if (rawQ != null && rawQ.isNotEmpty) {
            try {
              final qMap = jsonDecode(rawQ);
              if (qMap is Map) {
                final b = (qMap['budget'] as num?)?.toDouble() ?? 0.0;
                final m = (qMap['month'] as String? ?? '').trim();
                if (b > 0) {
                  savedQuickBudget = b;
                  savedQuickMonth = m;
                }
              }
            } catch (_) {}
          }
        }

        for (final entry in itemsByMonth.entries) {
          final monthTitle = entry.key;
          final itemsMap = entry.value;
          if (itemsMap.isEmpty) continue;

          final existingCount = Sqflite.firstIntValue(
                await db.rawQuery('SELECT COUNT(*) FROM items WHERE month_title = ?', [monthTitle]),
              ) ??
              0;

          if (existingCount < itemsMap.length) {
            final budget = (savedQuickMonth == monthTitle && savedQuickBudget > 0) ? savedQuickBudget : 0.0;
            await db.insert(
              'months',
              {
                'title': monthTitle,
                'budget': budget,
                'total': 0.0,
                'balance': budget,
                'totalItems': itemsMap.length.toDouble(),
                'boughtItems': 0.0,
                'is_finalized': 0,
                'purpose': 'geral',
                'workspace': 'personal',
              },
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );

            final existingDbItems = await getItems(monthTitle);
            final existingNames = existingDbItems.map((e) => Utils.normalize(e.name)).toSet();
            final restoredItems = List<Item>.from(existingDbItems);
            int idx = restoredItems.isEmpty
                ? 7
                : (restoredItems.map((e) => e.index ?? 0).fold<int>(0, (a, b) => a > b ? a : b) + 1);

            for (final itData in itemsMap.values) {
              final name = itData['name'] as String;
              if (name.isEmpty || existingNames.contains(Utils.normalize(name))) continue;
              final price = (itData['price'] as num?)?.toDouble() ?? 0.0;
              restoredItems.add(Item(
                index: idx++,
                name: name,
                quantity: 1.0,
                unitPrice: price,
                isKg: false,
                category: (itData['category'] as String?) ?? 'Outros',
                isBought: false,
                barcode: itData['barcode'] as String?,
                supermarket: itData['supermarket'] as String?,
              ));
            }
            if (restoredItems.length > existingDbItems.length) {
              await saveItems(monthTitle, restoredItems);
              debugPrint('♻️ DatabaseHelper: Reconstruídos ${restoredItems.length - existingDbItems.length} itens do mês "$monthTitle" via cache_price_history_v2');
            }
          }
        }
      } catch (e) {
        debugPrint('Aviso ao reconstruir listas do histórico de preços: $e');
      }

      // 6. Último fallback: se o banco continuar com 0 itens, verifica `community_prices_cache` (compras locais do usuário)
      final totalItemsNow = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM items')) ?? 0;
      if (totalItemsNow == 0) {
        try {
          final localCommRows = await db.query(
            'community_prices_cache',
            where: "id LIKE 'local_%' OR submitted_by = 'Cliente CARRIN'",
          );
          if (localCommRows.isNotEmpty) {
            final now = DateTime.now();
            const monthsPt = [
              'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
              'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'
            ];
            final currentMonthTitle = '${monthsPt[now.month - 1]} ${now.year}';
            if (!isDeleted(currentMonthTitle)) {
              final List<Item> commRecovered = [];
              int idx = 7;
              final Set<String> seenNames = {};
              for (final r in localCommRows) {
                final name = (r['product_name'] as String? ?? '').trim();
                final norm = Utils.normalize(name);
                if (name.isEmpty || seenNames.contains(norm)) continue;
                seenNames.add(norm);
                final price = (r['price'] as num?)?.toDouble() ?? 0.0;
                commRecovered.add(Item(
                  index: idx++,
                  name: name,
                  quantity: 1.0,
                  unitPrice: price,
                  isKg: (r['unit'] as String? ?? '') == 'kg',
                  category: (r['category'] as String?) ?? 'Outros',
                  isBought: false,
                  supermarket: r['supermarket_name'] as String?,
                ));
              }
              if (commRecovered.isNotEmpty) {
                await saveItems(currentMonthTitle, commRecovered);
                debugPrint('♻️ DatabaseHelper: Recuperados ${commRecovered.length} itens para "$currentMonthTitle" via community_prices_cache');
              }
            }
          }
        } catch (e) {
          debugPrint('Aviso ao recuperar de community_prices_cache: $e');
        }
      }

      // 7. Recalcula os resumos (total, totalItems, boughtItems, balance) e normaliza workspace em todos os meses
      final refreshedMonths = await db.query('months');
      for (final m in refreshedMonths) {
        final title = (m['title'] as String? ?? '').trim();
        if (title.isEmpty) continue;
        final ws = (m['workspace'] as String? ?? '').trim();
        final budget = (m['budget'] as num?)?.toDouble() ?? 0.0;
        final monthItems = await db.query('items', where: 'month_title = ?', whereArgs: [title]);
        if (monthItems.isNotEmpty) {
          double total = 0.0;
          int bought = 0;
          for (final it in monthItems) {
            final q = (it['quantity'] as num?)?.toDouble() ?? 0.0;
            final p = (it['unit_price'] as num?)?.toDouble() ?? 0.0;
            final isB = it['is_bought'] == 1;
            if (isB) {
              total += q * p;
              bought++;
            }
          }
          await db.update(
            'months',
            {
              'total': total,
              'balance': budget - total,
              'totalItems': monthItems.length.toDouble(),
              'boughtItems': bought.toDouble(),
              if (ws.isEmpty) 'workspace': 'personal',
            },
            where: 'title = ?',
            whereArgs: [title],
          );
        } else if (ws.isEmpty) {
          await db.update(
            'months',
            {'workspace': 'personal'},
            where: 'title = ?',
            whereArgs: [title],
          );
        }
      }

      // 8. Salva snapshot atualizado de segurança
      await saveLocalBackupSnapshot();
    } catch (e) {
      debugPrint('Erro em recoverAndConsolidateUserData: $e');
    }
  }
}
