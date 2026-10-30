import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/item.dart';
import 'auth_service.dart';
import 'utils.dart';

/// Service responsible for direct communication with Google Sheets API via user's account.
class UserSheetsService {
  String? _spreadsheetId;
  late String _currentSheetTitle;
  double _budget = 0.0;
  double _totalFromSheet = 0.0;
  String? _activeUserEmail;

  UserSheetsService() {
    _currentSheetTitle = _getRealCurrentMonthName();
  }

  void setActiveUserEmail(String? email) {
    if (_activeUserEmail?.toLowerCase() != email?.toLowerCase()) {
      _activeUserEmail = email;
      _spreadsheetId = null;
    }
  }

  String get _spreadsheetName {
    final googleEmail = AuthService().currentUser?.email.toLowerCase();
    final localEmail = _activeUserEmail?.toLowerCase();
    if (localEmail == null) {
      return 'CARRIN_Lista_Compras';
    }
    if (googleEmail != null && localEmail == googleEmail) {
      return 'CARRIN_Lista_Compras';
    }
    final safeEmail = localEmail.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return 'CARRIN_Lista_Compras_$safeEmail';
  }

  String _getRealCurrentMonthName() {
    final now = DateTime.now();
    final monthsPt = [
      'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
      'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'
    ];
    return '${monthsPt[now.month - 1]} ${now.year}';
  }

  sheets.SheetsApi? get _sheetsApi {
    final client = AuthService().authClient;
    if (client == null) return null;
    return sheets.SheetsApi(client);
  }

  drive.DriveApi? get _driveApi {
    final client = AuthService().authClient;
    if (client == null) return null;
    return drive.DriveApi(client);
  }

  void reset() {
    _spreadsheetId = null;
    _budget = 0.0;
    _totalFromSheet = 0.0;
    _currentSheetTitle = _getRealCurrentMonthName();
  }

  void setCurrentTitle(String title) {
    _currentSheetTitle = title;
  }

  Future<void> init({String? title}) async {
    if (title != null) _currentSheetTitle = title;
    await _ensureSpreadsheetExists();
  }

  /// Extracts a Google Spreadsheet ID from either a full URL or a raw ID string.
  static String extractSpreadsheetId(String input) {
    final clean = input.trim();
    final regExp = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');
    final match = regExp.firstMatch(clean);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)!;
    }
    return clean;
  }

  /// Sets a custom Google Spreadsheet ID or URL, or clears it to use the default Drive sheet.
  Future<void> setCustomSpreadsheetId(String? rawInput) async {
    final prefs = await SharedPreferences.getInstance();
    if (rawInput == null || rawInput.trim().isEmpty) {
      await prefs.remove('custom_spreadsheet_id');
      _spreadsheetId = null;
    } else {
      final parsedId = extractSpreadsheetId(rawInput);
      await prefs.setString('custom_spreadsheet_id', parsedId);
      _spreadsheetId = parsedId;
    }
  }

  /// Returns the current custom spreadsheet ID from SharedPreferences if configured.
  Future<String?> getCustomSpreadsheetId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('custom_spreadsheet_id');
  }

  /// Retorna o ID da planilha ativa (garante existência no Google Drive caso necessário).
  Future<String?> getActiveSpreadsheetId() async {
    try {
      await _ensureSpreadsheetExists();
      return _spreadsheetId;
    } catch (e) {
      debugPrint('Erro ao obter spreadsheetId ativo: \$e');
      return null;
    }
  }

  /// Retorna a URL completa de edição da planilha no Google Docs.
  Future<String?> getActiveSpreadsheetUrl() async {
    final id = await getActiveSpreadsheetId();
    if (id == null) return null;
    return 'https://docs.google.com/spreadsheets/d/\$id/edit';
  }

  /// Compartilha a planilha ativa diretamente com outro usuário Google (via Google Drive Permissions API).
  Future<bool> shareSpreadsheetWithEmail(String email, {bool asWriter = true}) async {
    final driveApi = _driveApi;
    final ssId = await getActiveSpreadsheetId();
    if (driveApi == null || ssId == null) return false;

    try {
      final permission = drive.Permission(
        role: asWriter ? 'writer' : 'reader',
        type: 'user',
        emailAddress: email.trim(),
      );
      await driveApi.permissions.create(
        permission,
        ssId,
        sendNotificationEmail: true,
      );
      return true;
    } catch (e) {
      debugPrint('Erro ao compartilhar planilha com \$email: \$e');
      return false;
    }
  }

  /// Concede permissão de edição para qualquer pessoa com o link da planilha no Google Drive.
  Future<String?> makeSpreadsheetPublicWithLink() async {
    final driveApi = _driveApi;
    final ssId = await getActiveSpreadsheetId();
    if (driveApi == null || ssId == null) return null;

    try {
      final permission = drive.Permission(
        role: 'writer',
        type: 'anyone',
      );
      await driveApi.permissions.create(
        permission,
        ssId,
      );
    } catch (e) {
      debugPrint('Aviso ao liberar link publico no Google Drive: \$e');
    }
    return 'https://docs.google.com/spreadsheets/d/\$ssId/edit';
  }

  /// Verifica se o usuário está conectado a uma planilha compartilhada (personalizada).
  Future<bool> isUsingCustomSharedSpreadsheet() async {
    final custom = await getCustomSpreadsheetId();
    return custom != null && custom.trim().isNotEmpty;
  }

  /// Restaura para a planilha padrão pessoal do usuário no Google Drive.
  Future<void> restoreDefaultSpreadsheet() async {
    await setCustomSpreadsheetId(null);
  }

  bool _isDummyTabName(String title) {
    final lower = title.trim().toLowerCase();
    return lower.isEmpty ||
        lower == 'página1' ||
        lower == 'página 1' ||
        lower == 'pagina1' ||
        lower == 'pagina 1' ||
        lower == 'sheet1' ||
        lower == 'sheet 1';
  }

  Future<void> _ensureSpreadsheetExists() async {
    if (_spreadsheetId != null) return;

    // 1. Prioriza planilha personalizada configurada pelo usuário
    final customId = await getCustomSpreadsheetId();
    if (customId != null && customId.trim().isNotEmpty) {
      _spreadsheetId = customId.trim();
      return;
    }

    final driveApi = _driveApi;
    final sheetsApi = _sheetsApi;
    if (driveApi == null || sheetsApi == null) throw Exception('Usuário não autenticado');

    final response = await driveApi.files.list(
      q: "name contains 'CARRIN_Lista_Compras' and mimeType = 'application/vnd.google-apps.spreadsheet' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id, name, modifiedTime)',
    );

    final files = response.files ?? [];
    if (files.isNotEmpty) {
      // Ordena priorizando correspondência exata com _spreadsheetName ou 'CARRIN_Lista_Compras'
      files.sort((a, b) {
        final aExact = a.name == _spreadsheetName ? 0 : (a.name == 'CARRIN_Lista_Compras' ? 1 : 2);
        final bExact = b.name == _spreadsheetName ? 0 : (b.name == 'CARRIN_Lista_Compras' ? 1 : 2);
        return aExact.compareTo(bExact);
      });

      if (files.length == 1) {
        _spreadsheetId = files.first.id;
      } else {
        // Se houver múltiplas planilhas (ex: uma vazia recém-criada e outra com as listas reais),
        // escolhe aquela que possui mais abas reais (além de Página1/Sheet1).
        String? bestId = files.first.id;
        int bestRealTabCount = -1;
        for (final f in files.take(5)) {
          final fid = f.id;
          if (fid == null) continue;
          try {
            final ss = await sheetsApi.spreadsheets.get(fid);
            final realTabs = ss.sheets
                    ?.map((s) => s.properties?.title ?? '')
                    .where((t) => !_isDummyTabName(t))
                    .length ??
                0;
            if (realTabs > bestRealTabCount) {
              bestRealTabCount = realTabs;
              bestId = fid;
            }
          } catch (_) {}
        }
        _spreadsheetId = bestId;
      }
    } else {
      var file = drive.File()
        ..name = _spreadsheetName
        ..mimeType = 'application/vnd.google-apps.spreadsheet';
      final created = await driveApi.files.create(file);
      _spreadsheetId = created.id;
    }
  }

  Future<Map<String, Map<String, double>>> getBatchSummaries(List<String> titles) async {
    final Map<String, Map<String, double>> summaries = {};
    if (titles.isEmpty) return summaries;
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return summaries;

    try {
      final List<String> ranges = [];
      for (final t in titles) {
        final escaped = t.replaceAll("'", "''");
        ranges.add("'$escaped'!A2:I2");
        ranges.add("'$escaped'!B7:I");
      }

      final response = await api.spreadsheets.values.batchGet(_spreadsheetId!, ranges: ranges);
      final valueRanges = response.valueRanges ?? [];

      for (int i = 0; i < titles.length; i++) {
        final title = titles[i];
        final row2Values = (i * 2 < valueRanges.length) ? valueRanges[i * 2].values : null;
        final itemRows = (i * 2 + 1 < valueRanges.length) ? valueRanges[i * 2 + 1].values : null;

        double row2Total = 0.0;
        double row2TotalItems = 0.0;
        double row2BoughtItems = 0.0;
        double budget = 0.0;
        bool isFinalized = false;

        if (row2Values != null && row2Values.isNotEmpty) {
          final row2 = row2Values.first;
          row2Total = row2.length > 2 ? _parseBrazilianNumber(row2[2].toString()) : 0.0;
          row2TotalItems = row2.length > 4 ? _parseBrazilianNumber(row2[4].toString()) : 0.0;
          row2BoughtItems = row2.length > 5 ? _parseBrazilianNumber(row2[5].toString()) : 0.0;
          budget = row2.length > 7 ? _parseBrazilianNumber(row2[7].toString()) : 0.0;
          isFinalized = row2.length > 8 ? Item.parseBool(row2[8]) : false;
        }

        // Calculate real items metrics from Column B to I
        int countItems = 0;
        int countBought = 0;
        double sumTotal = 0.0;

        if (itemRows != null && itemRows.isNotEmpty) {
          for (final row in itemRows) {
            if (row.length > 1 && row[1].toString().trim().isNotEmpty) {
              countItems++;
              final isBought = row.length > 5 ? Item.parseBool(row[5]) : false;
              final qty = row.isNotEmpty ? _parseBrazilianNumber(row[0].toString()) : 0.0;
              final unitPrice = row.length > 2 ? _parseBrazilianNumber(row[2].toString()) : 0.0;
              final rowTotal = row.length > 3 ? _parseBrazilianNumber(row[3].toString()) : (qty * unitPrice);

              if (isBought) {
                countBought++;
                sumTotal += (rowTotal > 0 ? rowTotal : (qty * unitPrice));
              }
            }
          }
        }

        double finalTotal = row2Total;
        double finalTotalItems = row2TotalItems;
        double finalBoughtItems = row2BoughtItems;
        bool needsHeal = false;

        if (countItems > 0) {
          if (row2Total == 0.0 && sumTotal > 0.0) {
            finalTotal = sumTotal;
            needsHeal = true;
          } else if ((row2Total - sumTotal).abs() > 0.01) {
            finalTotal = sumTotal;
            needsHeal = true;
          }
          if (row2TotalItems == 0.0 || (row2TotalItems - countItems).abs() > 0.01) {
            finalTotalItems = countItems.toDouble();
            needsHeal = true;
          }
          if (row2BoughtItems == 0.0 || (row2BoughtItems - countBought).abs() > 0.01) {
            finalBoughtItems = countBought.toDouble();
            needsHeal = true;
          }
        }

        final double finalBalance = budget - finalTotal;

        summaries[title] = {
          'budget': budget,
          'total': finalTotal,
          'balance': finalBalance,
          'totalItems': finalTotalItems,
          'boughtItems': finalBoughtItems,
          'isFinalized': isFinalized ? 1.0 : 0.0,
        };

        if (needsHeal) {
          unawaited(_healSummaryRow(title, budget, isFinalized));
        }
      }
    } catch (e) {
      debugPrint('Erro no Batch Summaries: $e');
      rethrow;
    }
    return summaries;
  }

  Future<void> _healSummaryRow(String title, double budget, bool isFinalized) async {
    try {
      final api = _sheetsApi;
      if (api == null || _spreadsheetId == null) return;
      final formulas = [
        '=IFERROR(SUMIF(G7:G, TRUE, E7:E), 0)',
        '',
        '=IFERROR(COUNTA(C7:C), 0)',
        '=IFERROR(COUNTIF(G7:G, TRUE), 0)',
        '=IFERROR(H2-C2, 0)'
      ];
      final vr = sheets.ValueRange()..values = [formulas];
      await api.spreadsheets.values.update(
        vr, _spreadsheetId!, "'${title.replaceAll("'", "''")}'!C2:G2",
        valueInputOption: 'USER_ENTERED'
      );
    } catch (e) {
      debugPrint('Aviso ao regenerar fórmulas na aba $title: $e');
    }
  }

  Future<Map<String, double>> getSummaryOnly(String title) async {
    final res = await getBatchSummaries([title]);
    return res[title] ?? {'budget': 0.0, 'total': 0.0, 'balance': 0.0, 'totalItems': 0.0, 'boughtItems': 0.0, 'isFinalized': 0.0};
  }

  Future<List<String>> getAvailableMonths() async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) throw Exception('Sheets API indisponível');

    try {
      final ss = await api.spreadsheets.get(_spreadsheetId!);
      final list = ss.sheets?.map((s) => s.properties?.title ?? '').where((t) => t.isNotEmpty).toList() ?? [];
      return list.where((t) => !_isDummyTabName(t)).toList();
    } catch (e) {
      debugPrint('Erro ao obter meses disponíveis: $e');
      rethrow;
    }
  }

  Future<void> updateBudget(double newBudget) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      final vr = sheets.ValueRange()..values = [[newBudget]];
      await api.spreadsheets.values.update(
        vr, _spreadsheetId!, "'$_currentSheetTitle'!H2",
        valueInputOption: 'USER_ENTERED'
      );
      _budget = newBudget;
    } catch (e) {
      if (e.toString().contains('Unable to parse range')) {
        try {
          debugPrint('Aba "$_currentSheetTitle" não encontrada ao atualizar orçamento. Criando automaticamente...');
          await createNewMonth(_currentSheetTitle, false);
          final vr = sheets.ValueRange()..values = [[newBudget]];
          await api.spreadsheets.values.update(
            vr, _spreadsheetId!, "'$_currentSheetTitle'!H2",
            valueInputOption: 'USER_ENTERED'
          );
          _budget = newBudget;
          return;
        } catch (retryError) {
          debugPrint('Erro ao atualizar orçamento após auto-criação: $retryError');
        }
      }
      debugPrint('Erro ao atualizar orçamento: $e');
      rethrow;
    }
  }

  Future<void> updateSummary(String title, double total, double balance, {int? totalItems, int? boughtItems, bool? isFinalized, double? budget}) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    final escapedTitle = title.replaceAll("'", "''");
    final formulas = [
      '=IFERROR(SUMIF(G7:G, TRUE, E7:E), 0)',
      '',
      '=IFERROR(COUNTA(C7:C), 0)',
      '=IFERROR(COUNTIF(G7:G, TRUE), 0)',
      '=IFERROR(H2-C2, 0)'
    ];

    try {
      final vr = sheets.ValueRange()..values = [formulas];
      await api.spreadsheets.values.update(
        vr, _spreadsheetId!, "'$escapedTitle'!C2:G2",
        valueInputOption: 'USER_ENTERED'
      );

      if (budget != null) {
        final vrBudget = sheets.ValueRange()..values = [[budget]];
        await api.spreadsheets.values.update(
          vrBudget, _spreadsheetId!, "'$escapedTitle'!H2",
          valueInputOption: 'USER_ENTERED'
        );
      }
      
      if (isFinalized != null) {
        final vrFinal = sheets.ValueRange()..values = [[isFinalized ? 'TRUE' : 'FALSE']];
        await api.spreadsheets.values.update(
          vrFinal, _spreadsheetId!, "'$escapedTitle'!I2",
          valueInputOption: 'USER_ENTERED'
        );
      }
    } catch (e) {
      if (e.toString().contains('Unable to parse range')) {
        try {
          debugPrint('Aba "$title" não encontrada ao atualizar resumo. Criando automaticamente...');
          await createNewMonth(title, false, initialBudget: budget);
          final vr = sheets.ValueRange()..values = [formulas];
          await api.spreadsheets.values.update(
            vr, _spreadsheetId!, "'$escapedTitle'!C2:G2",
            valueInputOption: 'USER_ENTERED'
          );
          if (isFinalized != null) {
            final vrFinal = sheets.ValueRange()..values = [[isFinalized ? 'TRUE' : 'FALSE']];
            await api.spreadsheets.values.update(
              vrFinal, _spreadsheetId!, "'$escapedTitle'!I2",
              valueInputOption: 'USER_ENTERED'
            );
          }
          return;
        } catch (retryError) {
          debugPrint('Erro ao atualizar resumo após auto-criação: $retryError');
        }
      }
      debugPrint('Erro ao atualizar resumo: $e');
      rethrow;
    }
  }

  Future<void> overwriteAllItems(String monthTitle, List<Item> localItems) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    final escapedTitle = monthTitle.replaceAll("'", "''");
    final formulas = [
      '=IFERROR(SUMIF(G7:G, TRUE, E7:E), 0)',
      '',
      '=IFERROR(COUNTA(C7:C), 0)',
      '=IFERROR(COUNTIF(G7:G, TRUE), 0)',
      '=IFERROR(H2-C2, 0)'
    ];

    try {
      // Clear existing
      await api.spreadsheets.values.clear(sheets.ClearValuesRequest(), _spreadsheetId!, "'$escapedTitle'!B7:I");

      // Insert new
      if (localItems.isNotEmpty) {
        final List<List<dynamic>> matrix = localItems.map((item) => item.toList()).toList();
        final vr = sheets.ValueRange()..values = matrix;
        await api.spreadsheets.values.update(
          vr, _spreadsheetId!, "'$escapedTitle'!B7",
          valueInputOption: 'USER_ENTERED'
        );
      }

      // Also ensure row 2 summary formulas are present and working
      final vrSummary = sheets.ValueRange()..values = [formulas];
      await api.spreadsheets.values.update(
        vrSummary, _spreadsheetId!, "'$escapedTitle'!C2:G2",
        valueInputOption: 'USER_ENTERED'
      );
    } catch (e) {
      final err = e.toString().toLowerCase();
      if (err.contains('unable to parse range') || err.contains('not found') || err.contains('cannot find sheet')) {
        try {
          debugPrint('Aba "$monthTitle" não encontrada ao sobrescrever. Criando automaticamente...');
          await createNewMonth(monthTitle, false);
          await api.spreadsheets.values.clear(sheets.ClearValuesRequest(), _spreadsheetId!, "'$escapedTitle'!B7:I");
          if (localItems.isNotEmpty) {
            final List<List<dynamic>> matrix = localItems.map((item) => item.toList()).toList();
            final vr = sheets.ValueRange()..values = matrix;
            await api.spreadsheets.values.update(
              vr, _spreadsheetId!, "'$escapedTitle'!B7",
              valueInputOption: 'USER_ENTERED'
            );
          }
          final vrSummary = sheets.ValueRange()..values = [formulas];
          await api.spreadsheets.values.update(
            vrSummary, _spreadsheetId!, "'$escapedTitle'!C2:G2",
            valueInputOption: 'USER_ENTERED'
          );
          return;
        } catch (retryError) {
          debugPrint('Erro ao sobrescrever após auto-criação: $retryError');
        }
      }
      debugPrint('Erro ao sobrescrever itens: $e');
      rethrow;
    }
  }

  Future<void> createNewMonth(String newTitle, bool useTemplate, {double? initialBudget, String? sourceMonth}) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      // Verify if sheet already exists
      final ss = await api.spreadsheets.get(_spreadsheetId!);
      final exists = ss.sheets?.any((s) => s.properties?.title == newTitle) ?? false;
      
      if (!exists) {
        // Create the sheet
        final addSheetReq = sheets.Request()
          ..addSheet = (sheets.AddSheetRequest()
            ..properties = (sheets.SheetProperties()..title = newTitle));
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest()..requests = [addSheetReq],
          _spreadsheetId!
        );
      }

      // Setup Headers
      final vr = sheets.ValueRange()
        ..values = [
          ['Lista de Compras', '', 'Total Gasto', '', 'Qtd Itens', 'Comprados', 'Saldo', 'Orçamento', 'Finalizado'],
          ['', '', '=IFERROR(SUMIF(G7:G, TRUE, E7:E), 0)', '', '=IFERROR(COUNTA(C7:C), 0)', '=IFERROR(COUNTIF(G7:G, TRUE), 0)', '=IFERROR(H2-C2, 0)', initialBudget ?? 0, 'FALSE'],
          ['', '', '', '', '', '', '', '', ''],
          ['', '', '', '', '', '', '', '', ''],
          ['', '', '', '', '', '', '', '', ''],
          ['', 'Qtd', 'Produto', 'Preço Unit.', 'Total', 'Categoria', 'Comprado', 'Barcode', 'Mercado']
        ];
      
      await api.spreadsheets.values.update(
        vr, _spreadsheetId!, "'$newTitle'!A1",
        valueInputOption: 'USER_ENTERED'
      );

      // Copy template
      if (useTemplate) {
        try {
          final src = sourceMonth ?? _currentSheetTitle;
          final sourceItems = await getItems(title: src);
          if (sourceItems.isNotEmpty) {
            List<List<dynamic>> templateItems = [];
            for (var item in sourceItems) {
              if (item.name.trim().isNotEmpty) {
                templateItems.add([
                  item.isKg ? 0.0 : 0,
                  item.name,
                  item.unitPrice,
                  0,
                  item.category.isNotEmpty ? item.category : 'Outros',
                  'FALSE',
                  Item.parseBarcode(item.barcode) ?? '',
                  item.supermarket ?? '',
                ]);
              }
            }
            if (templateItems.isNotEmpty) {
              final vrTemplate = sheets.ValueRange()..values = templateItems;
              await api.spreadsheets.values.update(
                vrTemplate, _spreadsheetId!, "'$newTitle'!B7",
                valueInputOption: 'USER_ENTERED'
              );
            }
          }
        } catch (templateError) {
          debugPrint('Aviso: Falha ao copiar template do mês anterior "$sourceMonth": $templateError');
          // Não relançar erro para permitir que o mês seja criado com sucesso mesmo sem template
        }
      }
      
      _currentSheetTitle = newTitle;
      _budget = initialBudget ?? 0.0;
      _totalFromSheet = 0.0;
    } catch (e) {
      debugPrint('Erro ao criar novo mês: $e');
      rethrow;
    }
  }

  String get currentMonthTitle => _currentSheetTitle;
  double get budget => _budget;
  double get totalFromSheet => _totalFromSheet;

  double _parseBrazilianNumber(String value) {
    return Utils.parseCurrency(value);
  }

  Future<List<Item>> getItems({String? title}) async {
    final targetTitle = title ?? _currentSheetTitle;
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return [];

    try {
      final response = await api.spreadsheets.values.get(_spreadsheetId!, "'$targetTitle'!B2:I");
      final allValues = response.values ?? [];

      if (allValues.isNotEmpty) {
        final row2 = allValues[0];
        if (title == null || title == _currentSheetTitle) {
          if (row2.length > 1) _totalFromSheet = _parseBrazilianNumber(row2[1].toString());
          if (row2.length > 6) _budget = _parseBrazilianNumber(row2[6].toString());
        }
      }

      List<Item> items = [];
      int startIdx = 5;
      final bool hasStandardHeader = allValues.length >= 6 &&
          allValues[4].any((cell) {
            final s = cell.toString().toLowerCase();
            return s.contains('produto') || s.contains('qtd') || s.contains('preço');
          });

      if (!hasStandardHeader) {
        startIdx = 0;
        for (var i = 0; i < allValues.length; i++) {
          final rowStr = allValues[i].join(' ').toLowerCase();
          if (rowStr.contains('lista de compras') || rowStr.contains('total gasto') || rowStr.contains('produto')) {
            startIdx = i + 1;
          } else {
            break;
          }
        }
      }

      for (var i = startIdx; i < allValues.length; i++) {
        if (allValues[i].any((cell) => cell.toString().trim().isNotEmpty)) {
          final item = Item.fromList(allValues[i], i + 2);
          if (item.name.trim().isNotEmpty) {
            items.add(item);
          }
        }
      }
      return items;
    } catch (e) {
      if (e.toString().contains('Unable to parse range')) {
        try {
          debugPrint('Aba "$targetTitle" não encontrada ao carregar itens. Criando automaticamente...');
          await createNewMonth(targetTitle, false);
          final response = await api.spreadsheets.values.get(_spreadsheetId!, "'$targetTitle'!B2:I");
          final allValues = response.values ?? [];

          if (allValues.isNotEmpty) {
            final row2 = allValues[0];
            if (title == null || title == _currentSheetTitle) {
              if (row2.length > 1) _totalFromSheet = _parseBrazilianNumber(row2[1].toString());
              if (row2.length > 6) _budget = _parseBrazilianNumber(row2[6].toString());
            }
          }

          List<Item> items = [];
          if (allValues.length >= 6) {
            for (var i = 5; i < allValues.length; i++) {
              if (allValues[i].any((cell) => cell.toString().trim().isNotEmpty)) {
                items.add(Item.fromList(allValues[i], i + 2));
              }
            }
          }
          return items;
        } catch (retryError) {
          debugPrint('Erro ao buscar itens após auto-criação da aba: $retryError');
        }
      }
      debugPrint('Erro crítico ao buscar itens: $e');
      rethrow;
    }
  }

  Future<void> switchMonth(String month) async {
    await init(title: month);
  }

  Future<void> addItem(Item item) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      final vr = sheets.ValueRange()..values = [item.toList()];
      await api.spreadsheets.values.append(
        vr, _spreadsheetId!, "'$_currentSheetTitle'!B7",
        valueInputOption: 'USER_ENTERED'
      );
    } catch (e) {
      debugPrint('Erro ao adicionar item: $e');
      rethrow;
    }
  }

  Future<void> updateItem(Item item) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null || item.index == null) return;

    try {
      final vr = sheets.ValueRange()..values = [item.toList()];
      await api.spreadsheets.values.update(
        vr, _spreadsheetId!, "'$_currentSheetTitle'!B${item.index}:I${item.index}",
        valueInputOption: 'USER_ENTERED'
      );
    } catch (e) {
      debugPrint('Erro ao atualizar item: $e');
      rethrow;
    }
  }

  Future<void> removeItem(int index) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      // Sheets API delete row requires the sheet ID (number), not the name.
      final ss = await api.spreadsheets.get(_spreadsheetId!);
      // Use where(...).firstOrNull to avoid StateError if sheet is missing
      final sheetsList = ss.sheets?.where((s) => s.properties?.title == _currentSheetTitle).toList();
      final sheet = (sheetsList != null && sheetsList.isNotEmpty) ? sheetsList.first : null;
      
      if (sheet != null) {
        final sheetId = sheet.properties?.sheetId;
        final req = sheets.Request()
          ..deleteDimension = (sheets.DeleteDimensionRequest()
            ..range = (sheets.DimensionRange()
              ..sheetId = sheetId
              ..dimension = 'ROWS'
              ..startIndex = index - 1
              ..endIndex = index));
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest()..requests = [req],
          _spreadsheetId!
        );
      }
    } catch (e) {
      debugPrint('Erro ao remover item: $e');
      rethrow;
    }
  }

  Future<void> deleteMonth(String title) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      final ss = await api.spreadsheets.get(_spreadsheetId!);
      
      // Se houver apenas 1 aba ativa no Google Sheets, não podemos deletá-la diretamente
      // (a API do Sheets exige no mínimo 1 aba). Portanto, criamos a "Página 1" antes de excluir.
      final totalSheets = ss.sheets?.length ?? 0;
      if (totalSheets <= 1) {
        final addSheetReq = sheets.Request()
          ..addSheet = (sheets.AddSheetRequest()
            ..properties = (sheets.SheetProperties()..title = 'Página 1'));
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest()..requests = [addSheetReq],
          _spreadsheetId!
        );
      }

      final sheetsList = ss.sheets?.where((s) => s.properties?.title == title).toList();
      final sheet = (sheetsList != null && sheetsList.isNotEmpty) ? sheetsList.first : null;
      
      if (sheet != null) {
        final sheetId = sheet.properties?.sheetId;
        final req = sheets.Request()
          ..deleteSheet = (sheets.DeleteSheetRequest()..sheetId = sheetId);
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest()..requests = [req],
          _spreadsheetId!
        );
      }
    } catch (e) {
      debugPrint('Erro ao deletar mês: $e');
      rethrow;
    }
  }

  Future<void> renameMonth(String oldTitle, String newTitle) async {
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return;

    try {
      final ss = await api.spreadsheets.get(_spreadsheetId!);
      // Use where(...).firstOrNull to avoid StateError
      final sheetsList = ss.sheets?.where((s) => s.properties?.title == oldTitle).toList();
      final sheet = (sheetsList != null && sheetsList.isNotEmpty) ? sheetsList.first : null;
      
      if (sheet != null) {
        final sheetId = sheet.properties?.sheetId;
        final req = sheets.Request()
          ..updateSheetProperties = (sheets.UpdateSheetPropertiesRequest()
            ..properties = (sheets.SheetProperties()..sheetId = sheetId..title = newTitle)
            ..fields = 'title');
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest()..requests = [req],
          _spreadsheetId!
        );
        if (_currentSheetTitle == oldTitle) _currentSheetTitle = newTitle;
      }
    } catch (e) {
      debugPrint('Erro ao renomear mês: $e');
      rethrow;
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> getFullPriceHistory() async {
    final Map<String, List<Map<String, dynamic>>> history = {};
    if (_spreadsheetId == null) await _ensureSpreadsheetExists();
    final api = _sheetsApi;
    if (api == null) return history;

    void addRowToHistory(dynamic row, String month) {
      if (row is List && row.length >= 2 && row[1].toString().trim().isNotEmpty) {
        final rawName = row[1].toString().trim();
        final normalized = Utils.normalize(rawName);
        final price = row.length >= 3 ? _parseBrazilianNumber(row[2].toString()) : 0.0;
        final rawBarcode = row.length > 6 ? row[6].toString().trim() : '';
        final barcode = Item.parseBarcode(rawBarcode) ?? '';
        final category = row.length > 4 ? row[4].toString().trim() : 'Outros';

        if (price > 0 || barcode.isNotEmpty) {
          final list = history.putIfAbsent(normalized, () => []);
          final existingIdx = list.indexWhere((e) => e['month'] == month);
          final entryData = {
            'name': rawName,
            'month': month,
            'price': price,
            'category': category,
            'barcode': barcode,
          };
          if (existingIdx != -1) {
            if ((entryData['barcode'] as String).isEmpty && (list[existingIdx]['barcode'] as String? ?? '').isNotEmpty) {
              entryData['barcode'] = list[existingIdx]['barcode'];
            }
            if (entryData['price'] == 0 && (list[existingIdx]['price'] as num? ?? 0) > 0) {
              entryData['price'] = list[existingIdx]['price'];
            }
            list[existingIdx] = entryData;
          } else {
            list.add(entryData);
          }
        }
      }
    }

    try {
      final months = await getAvailableMonths();
      if (months.isEmpty) return history;

      // 1. Tenta buscar todos os meses em lote (batchGet) em uma única requisição HTTP
      try {
        final ranges = months.map((m) => "'${m.replaceAll("'", "''")}'!B7:I").toList();
        final response = await api.spreadsheets.values.batchGet(_spreadsheetId!, ranges: ranges);
        final valueRanges = response.valueRanges ?? [];

        for (int i = 0; i < months.length && i < valueRanges.length; i++) {
          final month = months[i];
          final rows = valueRanges[i].values;
          if (rows != null) {
            for (var row in rows) {
              addRowToHistory(row, month);
            }
          }
        }
      } catch (batchErr) {
        debugPrint('Aviso: batchGet de histórico de preços falhou ($batchErr). Tentando buscar abas individualmente...');
        // Fallback resiliente: busca abas individualmente caso batchGet falhe
        for (var month in months) {
          try {
            final response = await api.spreadsheets.values.get(_spreadsheetId!, "'${month.replaceAll("'", "''")}'!B7:I");
            if (response.values != null) {
              for (var row in response.values!) {
                addRowToHistory(row, month);
              }
            }
          } catch (singleErr) {
            debugPrint('Erro ao buscar histórico da aba $month: $singleErr');
          }
        }
      }
    } catch (e) {
      debugPrint('Erro geral ao buscar histórico total da nuvem: $e');
    }
    return history;
  }
}
