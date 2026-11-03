import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/item.dart';
import '../models/sync_operation.dart';
import '../services/user_sheets_service.dart';
import '../services/notification_service.dart';
import '../services/utils.dart';
import '../services/database_helper.dart';
import '../services/auth_service.dart';
import '../services/quick_summary_service.dart';
import '../services/location_service.dart';
import '../services/community_price_service.dart';

/// Main state management provider for the application.
/// 
/// Coordinates data flow between [UserSheetsService] (cloud), [SharedPreferences] (local cache),
/// and the UI. Handles item CRUD, month management, and background synchronization.
class ItemProvider with ChangeNotifier {
  late final Future<void> initialization;

  static const List<String> defaultEssentialItems = [
    'Arroz',
    'Feijão',
    'Açúcar',
    'Café',
    'Sal',
    'Óleo de Soja',
    'Macarrão',
    'Molho de Tomate',
    'Farinha de Trigo',
    'Pipoca',
    'Farinha de Mandioca',
    'Fubá',
    'Creme de Leite',
    'Leite Condensado',
    'Milho em conserva',
    'Ervilha em conserva',
    'Atum em lata',
    'Sardinha em lata',
    'Leite',
    'Ovos',
    'Manteiga',
    'Margarina',
    'Queijo Muçarela',
    'Presunto',
    'Peito de Peru',
    'Frango',
    'Carne Moída',
    'Iogurte',
    'Cebola',
    'Alho',
    'Batata',
    'Tomate',
    'Cenoura',
    'Banana',
    'Maçã',
    'Laranja',
    'Alface',
    'Limão',
    'Pão de Forma',
    'Pão Francês',
    'Biscoito Cream Cracker',
    'Biscoito Recheado',
    'Papel Higiênico',
    'Sabonete',
    'Creme Dental',
    'Shampoo',
    'Condicionador',
    'Desodorante',
    'Fio Dental',
    'Algodão',
    'Detergente',
    'Sabão em Pó',
    'Amaciante',
    'Desinfetante',
    'Água Sanitária',
    'Esponja de Cozinha',
    'Lã de Aço',
    'Sabão em Barra',
    'Sacos de Lixo',
    'Papel Toalha',
    'Guardanapo',
  ];

  String? _activeUserEmail;
  String? get activeUserEmail => _activeUserEmail;
  bool _isReloadingUserData = false;
  String? _lastSyncError;
  String? get lastSyncError => _lastSyncError;

  String? _customSpreadsheetId;
  String? get customSpreadsheetId => _customSpreadsheetId;
  bool get hasCustomSpreadsheet => _customSpreadsheetId != null && _customSpreadsheetId!.isNotEmpty;

  String _activeUserDisplayName = 'Convidado';
  String _activeUserPhotoUrl = 'supermarket_cart';

  String get activeUserDisplayName => _activeUserDisplayName;
  String get activeUserPhotoUrl => _activeUserPhotoUrl;

  bool get isActiveUserOffline {
    if (_activeUserEmail == null) return true;
    return _activeUserEmail!.endsWith('@offline') || _activeUserEmail!.contains('@offline');
  }

  bool get isSyncEnabled {
    return AuthService().isSignedIn && _activeUserEmail != null && !isActiveUserOffline;
  }

  String get _userPrefsPrefix {
    if (_activeUserEmail == null || _activeUserEmail!.trim().isEmpty) return 'guest';
    return _activeUserEmail!.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
  }

  // --- Módulos: Mercados & GPS ---
  List<Map<String, dynamic>> _supermarkets = [];
  List<Map<String, dynamic>> get supermarkets => _supermarkets;
  Map<String, dynamic>? _detectedSupermarket;
  Map<String, dynamic>? get detectedSupermarket => _detectedSupermarket;
  String? _selectedSupermarketFilter;
  String? get selectedSupermarketFilter => _selectedSupermarketFilter;
  bool _isDetectingLocation = false;
  bool get isDetectingLocation => _isDetectingLocation;

  // --- Módulo: Finalidade do Carrinho (Purpose) ---
  String _currentMonthPurpose = 'geral'; // 'geral', 'abastecimento', 'conveniencia', 'churrasco'
  String get currentMonthPurpose => _currentMonthPurpose;

  // --- Módulo: Metas & Travas Orçamentárias por Categoria ---
  Map<String, double> _categoryCaps = {};
  Map<String, double> get categoryCaps => _categoryCaps;

  // --- Módulo: Workspace (Meu Carrinho vs Família) ---
  String _currentWorkspace = 'personal'; // 'personal' or 'family'
  String get currentWorkspace => _currentWorkspace;
  bool get isFamilyWorkspace => _currentWorkspace == 'family';

  // --- Módulo: Interação com o Gráfico de Análises ---
  bool _isInteractingWithChart = false;
  bool get isInteractingWithChart => _isInteractingWithChart;

  void setInteractingWithChart(bool value) {
    if (_isInteractingWithChart != value) {
      _isInteractingWithChart = value;
      notifyListeners();
    }
  }

  ItemProvider() {
    initialization = _initProvider();
  }

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<void> _updateActiveUserMetadata() async {
    final email = _activeUserEmail;
    if (email == null || email.isEmpty) {
      _activeUserDisplayName = 'Convidado';
      _activeUserPhotoUrl = 'supermarket_cart';
      _safeNotify();
      return;
    }

    // 1. Sempre dar preferência ao usuário ativo logado no Google se o e-mail for o mesmo
    final googleUser = AuthService().currentUser;
    if (googleUser != null && googleUser.email.trim().toLowerCase() == email.trim().toLowerCase()) {
      _activeUserDisplayName = googleUser.displayName ?? '';
      _activeUserPhotoUrl = googleUser.photoUrl ?? '';
      _safeNotify();
      return;
    }
    
    // 2. Se não estiver logado no momento (ou for offline), busca nas contas salvas
    final prefs = await SharedPreferences.getInstance();
    final String? accountsJson = prefs.getString('saved_google_accounts');
    if (accountsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(accountsJson);
        for (var e in decoded) {
          final map = Map<String, dynamic>.from(e);
          final accEmail = map['email']?.toString() ?? '';
          if (accEmail.trim().toLowerCase() == email.trim().toLowerCase()) {
            _activeUserDisplayName = map['displayName']?.toString() ?? 'Meu Perfil';
            final savedPhoto = map['photoUrl']?.toString();
            if (!email.endsWith('@offline') && (savedPhoto == null || savedPhoto.isEmpty)) {
              _activeUserPhotoUrl = '';
            } else {
              _activeUserPhotoUrl = savedPhoto ?? 'supermarket_cart';
            }
            _safeNotify();
            return;
          }
        }
      } catch (e) {
        debugPrint('Erro ao ler metadados do usuário ativo: $e');
      }
    }

    // 3. Fallback final se não achar em lugar nenhum
    _activeUserDisplayName = email.split('@').first;
    _activeUserPhotoUrl = email.endsWith('@offline') ? 'supermarket_cart' : '';
    _safeNotify();
  }

  Future<void> _initProvider() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Recupera a conta ativa salva. Se não houver, tenta usar a logada no Google.
    _activeUserEmail = prefs.getString('active_user_email');
    if (_activeUserEmail == null || _activeUserEmail!.isEmpty) {
      if (AuthService().currentUser != null) {
        _activeUserEmail = AuthService().currentUser?.email;
        if (_activeUserEmail != null) {
          await prefs.setString('active_user_email', _activeUserEmail!);
        }
      }
    }

    // Configura o banco de dados correspondente antes de qualquer operação
    DatabaseHelper.changeUser(_activeUserEmail);
    _service.setActiveUserEmail(_activeUserEmail);
    _customSpreadsheetId = await _service.getCustomSpreadsheetId();
    await _updateActiveUserMetadata();

    await _checkAndMigrateToSqlite();
    await _dbHelper.recoverAndConsolidateUserData();
    await loadSyncQueue(force: true);
    await purgeObsoleteSyncOperations();
    
    // Carrega configurações e listas locais IMEDIATAMENTE antes de serviços pesados
    await loadAnimationSettings();
    await loadEssentialItems();
    await _loadFullPriceHistory();

    try {
      final initialLocalMonths = await _dbHelper.getMonthsByWorkspace(_currentWorkspace);
      if (initialLocalMonths.isNotEmpty) {
        _months = List.from(initialLocalMonths);
        final summaries = await _dbHelper.getMonthsSummaries();
        _cachedSummary.addAll(summaries);
        final target = findVigentMonth(_months) ?? _months.last;
        final initialItems = await _dbHelper.getItems(target);
        _items = initialItems;
        _itemsCache[target] = initialItems;
        _service.setCurrentTitle(target);
        _isLoading = false;
        _safeNotify();
        _updateNotification();
      }
    } catch (e) {
      debugPrint('Aviso na carga rápida inicial do SQLite: $e');
    }

    await loadSupermarkets();
    await CommunityPriceService.instance.init();
    detectNearbySupermarket(notify: false);

    // Se a sincronização estiver ativada, processa a fila de sync
    if (isSyncEnabled && _syncQueue.isNotEmpty) {
      await processSyncQueue();
    }
    
    // Escuta mudanças na autenticação
    AuthService().addListener(_handleAuthChange);
    
    // Dispara a carga de dados iniciais
    if (AuthService().isSignedIn) {
      await _handleAuthChange();
    } else {
      await _loadMonths();
      await _loadDashboardData();
      if (_months.isNotEmpty) {
        final target = findVigentMonth(_months) ?? _months.last;
        await _switchMonth(target);
      }
    }

    // Processa lista importada via JSON se existir
    await _checkImportedJsonList();
  }

  Future<void> _checkImportedJsonList() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? imported = prefs.getStringList('imported_json_list');
    if (imported == null || imported.isEmpty) return;

    debugPrint('🔍 ItemProvider: Processando ${imported.length} itens importados via JSON...');
    
    // Se não houver meses, cria o mês atual primeiro
    if (_months.isEmpty) {
      await createNewMonth(realCurrentMonthName, false);
    }


    for (var name in imported) {
      final newItem = Item(
        index: _items.length + 7,
        name: name,
        quantity: 1,
        unitPrice: 0,
        category: 'Outros',
        isBought: false,
      );
      await addItem(newItem);
    }

    // Limpa a lista para não importar de novo no próximo boot
    await prefs.remove('imported_json_list');
    debugPrint('🔍 ItemProvider: Importação concluída com sucesso!');
  }

  Future<void> _handleAuthChange() async {
    final user = AuthService().currentUser;
    final prefs = await SharedPreferences.getInstance();
    
    if (user != null) {
      // Salva o usuário atual na lista de contas recentes
      await _saveAccountToRecents(user.email, user.displayName ?? '', user.photoUrl);
      
      // Sempre que um usuário loga no Google, torna essa conta a ativa
      _activeUserEmail = user.email;
      await prefs.setString('active_user_email', _activeUserEmail!);
      DatabaseHelper.changeUser(_activeUserEmail);
      _service.setActiveUserEmail(_activeUserEmail);
      await _updateActiveUserMetadata();
      await _reloadUserData();
    } else {
      // Usuário deslogado do Google. Sincronização em nuvem é desativada.
      // O usuário pode continuar vendo os dados locais.
      await _updateActiveUserMetadata();
      _safeNotify();
    }
  }

  Future<void> switchActiveUserEmail(String email) async {
    if (_activeUserEmail?.toLowerCase() == email.toLowerCase()) return;
    
    _activeUserEmail = email;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_user_email', email);
    
    // Altera o banco local
    DatabaseHelper.changeUser(email);
    _service.setActiveUserEmail(email);
    await _updateActiveUserMetadata();
    
    // Recarrega os dados locais
    await _reloadUserData();
  }

  Future<void> enableOfflineMode({String? displayName, String? photoUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    
    _activeUserEmail = 'offline@offline';
    await prefs.setString('active_user_email', _activeUserEmail!);
    
    // Salva o perfil local na lista de contas recentes
    await _saveAccountToRecents(_activeUserEmail!, displayName ?? 'Meu Perfil', photoUrl ?? 'supermarket_cart');
    
    DatabaseHelper.changeUser(_activeUserEmail);
    _service.setActiveUserEmail(_activeUserEmail);
    await _updateActiveUserMetadata();
    
    await _reloadUserData();
  }

  Future<void> createOfflineProfile(String email, String displayName, [String? photoUrl]) async {
    final prefs = await SharedPreferences.getInstance();
    
    _activeUserEmail = email;
    await prefs.setString('active_user_email', email);
    
    // Salva o perfil local na lista de contas recentes
    await _saveAccountToRecents(email, displayName, photoUrl ?? 'supermarket_cart');
    
    DatabaseHelper.changeUser(email);
    _service.setActiveUserEmail(email);
    await _updateActiveUserMetadata();
    await _reloadUserData();
  }

  Future<void> updateOfflineProfile(String email, String displayName, String photoUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final String? accountsJson = prefs.getString('saved_google_accounts');
    if (accountsJson == null) return;
    
    try {
      final List<dynamic> decoded = jsonDecode(accountsJson);
      final List<Map<String, dynamic>> accounts = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      
      bool updated = false;
      for (var acc in accounts) {
        if (acc['email']?.toString().trim().toLowerCase() == email.trim().toLowerCase()) {
          acc['displayName'] = displayName.trim();
          acc['photoUrl'] = photoUrl.trim();
          updated = true;
          break;
        }
      }
      
      if (updated) {
        await prefs.setString('saved_google_accounts', jsonEncode(accounts));
        if (_activeUserEmail?.trim().toLowerCase() == email.trim().toLowerCase()) {
          await _updateActiveUserMetadata();
        }
        _safeNotify();
      }
    } catch (e) {
      debugPrint('Erro ao atualizar perfil offline: $e');
    }
  }

  Future<void> removeSavedAccount(String email) async {
    debugPrint('🔍 removeSavedAccount: Iniciando para $email');
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Remove from saved accounts list
    final String? accountsJson = prefs.getString('saved_google_accounts');
    if (accountsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(accountsJson);
        final List<Map<String, dynamic>> accounts = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
        accounts.removeWhere((acc) => acc['email']?.toString().trim().toLowerCase() == email.trim().toLowerCase());
        await prefs.setString('saved_google_accounts', jsonEncode(accounts));
      } catch (e) {
        debugPrint('Erro ao remover conta da lista salva: $e');
      }
    }
    debugPrint('🔍 removeSavedAccount: Passo 1 concluído (lista de contas atualizada)');
    
    // 2. Remove profile keys
    final keys = prefs.getKeys();
    final safeEmail = email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final keysToRemove = keys.where((k) => k.endsWith('_$safeEmail')).toList();
    for (var key in keysToRemove) {
      await prefs.remove(key);
    }
    debugPrint('🔍 removeSavedAccount: Passo 2 concluído (chaves removidas)');
    
    // 3. Sign out of Google if the removed account is the active Google session
    final googleUser = AuthService().currentUser;
    if (googleUser != null && googleUser.email.trim().toLowerCase() == email.trim().toLowerCase()) {
      await AuthService().signOut();
    }
    debugPrint('🔍 removeSavedAccount: Passo 3 concluído (desconectado do Google)');
    
    // If the removed account is the active one, switch to guest first, then delete the database
    final bool isActive = _activeUserEmail?.trim().toLowerCase() == email.trim().toLowerCase();
    debugPrint('🔍 removeSavedAccount: isActive = $isActive');
    if (isActive) {
      _activeUserEmail = null;
      await prefs.remove('active_user_email');
      
      // Ensure the database is completely closed before any change or delete operation
      debugPrint('🔍 removeSavedAccount: Fechando banco de dados...');
      await DatabaseHelper.closeDatabase();
      debugPrint('🔍 removeSavedAccount: Banco fechado. Deletando banco de dados anterior...');
      
      // Deleta o banco de dados de forma síncrona (seguro agora que usa operações puras de File)
      await DatabaseHelper.deleteUserDatabase(email);
      debugPrint('🔍 removeSavedAccount: Banco anterior deletado. Mudando de usuário...');
      
      DatabaseHelper.changeUser(null);
      await _updateActiveUserMetadata();
      
      debugPrint('🔍 removeSavedAccount: Recarregando dados do usuário...');
      await _reloadUserData();
      debugPrint('🔍 removeSavedAccount: Dados recarregados.');
    } else {
      await _updateActiveUserMetadata();
      _safeNotify();
      
      // Deleta o banco não ativo de forma síncrona
      debugPrint('🔍 removeSavedAccount: Deletando banco de dados não ativo...');
      await DatabaseHelper.deleteUserDatabase(email);
      debugPrint('🔍 removeSavedAccount: Banco não ativo deletado.');
    }
    debugPrint('🔍 removeSavedAccount: Finalizado com sucesso.');
  }

  Future<void> removeAllSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final String? accountsJson = prefs.getString('saved_google_accounts');
    List<String> emails = [];
    if (accountsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(accountsJson);
        for (var e in decoded) {
          final map = Map<String, dynamic>.from(e);
          final email = map['email']?.toString();
          if (email != null && email.isNotEmpty) {
            emails.add(email);
          }
        }
      } catch (e) {
        debugPrint('Erro ao obter emails das contas salvas: $e');
      }
    }
    
    // Se a lista de contas salvas estiver vazia, mas houver um e-mail ativo, garanta que ele seja incluído
    if (emails.isEmpty && _activeUserEmail != null && _activeUserEmail!.isNotEmpty) {
      emails.add(_activeUserEmail!);
    }

    // Remove todas as contas salvas uma por uma (deleta arquivos do SQLite, chaves e desloga)
    for (var email in emails) {
      await removeSavedAccount(email);
    }

    // Garante que o Google esteja desconectado
    await AuthService().signOut();

    // Reseta estado local
    _activeUserEmail = null;
    await prefs.remove('active_user_email');
    await prefs.remove('saved_google_accounts');
    DatabaseHelper.changeUser(null);
    await _updateActiveUserMetadata();
    await _reloadUserData();
  }

  Future<void> forceReload() async {
    await _reloadUserData();
  }

  /// Sets a custom Google Spreadsheet by URL or ID and reloads all data.
  Future<void> setCustomSpreadsheet(String? input) async {
    await initialization;
    await _service.setCustomSpreadsheetId(input);
    _customSpreadsheetId = await _service.getCustomSpreadsheetId();
    _service.reset();
    _service.setActiveUserEmail(_activeUserEmail);

    _itemsCache.clear();
    _cachedSummary.clear();
    _badgeInfoCache.clear();
    _safeNotify();

    if (isSyncEnabled) {
      await _service.init();
      await _loadMonths();
      await _loadFullPriceHistory();
      if (_months.isNotEmpty) {
        final target = findVigentMonth(_months) ?? _months.last;
        await _switchMonth(target);
      }
    } else {
      await _loadMonths();
    }
  }

  /// Resets back to the default CARRIN spreadsheet in Google Drive.
  Future<void> resetToDefaultSpreadsheet() async {
    await setCustomSpreadsheet(null);
  }

  Future<void> _reloadUserData() async {
    if (_isReloadingUserData) return;
    _isReloadingUserData = true;

    try {
      _lastSyncError = null;
      _service.reset();
      _service.setActiveUserEmail(_activeUserEmail);
      _customSpreadsheetId = await _service.getCustomSpreadsheetId();

      // Limpa os caches temporários em memória da conta anterior
      _itemsCache.clear();
      _cachedSummary.clear();
      _priceHistoryCache.clear();
      _barcodeToHistoryCache.clear();
      _nameToBarcodeCache.clear();
      _badgeInfoCache.clear();
      _items = [];
      _months = [];
      _dashboardData = {
        'budget': 0.0,
        'total': 0.0,
        'balance': 0.0,
        'totalItems': 0.0,
        'boughtItems': 0.0,
      };

      // Auto-recupera e consolida listas antes de ler do SQLite
      await _dbHelper.recoverAndConsolidateUserData();

      // Carrega as configurações locais da conta atual instantaneamente
      await loadAnimationSettings();
      await loadEssentialItems();
      await _loadFullPriceHistory();
      
      // Carrega meses e resumos locais (SQLite) sem bloquear esperando rede
      try {
        final localMonths = await _dbHelper.getMonthsByWorkspace(_currentWorkspace);
        if (localMonths.isNotEmpty) {
          _months = localMonths;
          final summaries = await _dbHelper.getMonthsSummaries();
          _cachedSummary.addAll(summaries);
          final currentName = realCurrentMonthName;
          if (_cachedSummary.containsKey(currentName)) {
            _dashboardData = _cachedSummary[currentName]!;
          }
        }
      } catch (e) {
        debugPrint('Erro ao ler meses locais no reload: $e');
      }
      
      if (_months.isNotEmpty) {
        final target = findVigentMonth(_months) ?? _months.last;
        await _switchMonth(target);
      } else {
        _safeNotify();
      }
      
      // Sincronização em nuvem é disparada em background para não travar o login do usuário
      if (isSyncEnabled) {
        _runBackgroundUserDataSync();
      }
    } finally {
      _isReloadingUserData = false;
    }
  }

  void _runBackgroundUserDataSync() async {
    try {
      await _service.init();
      await loadSyncQueue(force: true);
      await purgeObsoleteSyncOperations();
      if (_syncQueue.isNotEmpty) {
        await processSyncQueue();
      }
      final hadNoMonths = _months.isEmpty;
      await _loadMonths();
      if (_months.isNotEmpty && (hadNoMonths || _items.isEmpty)) {
        final target = findVigentMonth(_months) ?? _months.last;
        await _switchMonth(target);
      }
      await _loadDashboardData(force: true);
    } catch (e) {
      debugPrint('Erro na sincronização em background pós-login: $e');
    }
  }

  Future<void> _saveAccountToRecents(String email, String displayName, String? photoUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final String? accountsJson = prefs.getString('saved_google_accounts');
    List<Map<String, dynamic>> accounts = [];
    
    if (accountsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(accountsJson);
        accounts = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (e) {
        debugPrint('Erro ao decodificar contas salvas: $e');
      }
    }
    
    // Remove se já existe para re-inserir no topo
    accounts.removeWhere((acc) => acc['email']?.toString().trim().toLowerCase() == email.trim().toLowerCase());
    
    accounts.insert(0, {
      'email': email.trim(),
      'displayName': displayName.trim(),
      'photoUrl': photoUrl ?? '',
      'isOffline': email.endsWith('@offline'),
    });
    
    // Limita às últimas 5 contas
    if (accounts.length > 5) {
      accounts = accounts.sublist(0, 5);
    }
    
    await prefs.setString('saved_google_accounts', jsonEncode(accounts));
  }

  /// List of pending offline sync operations.
  List<SyncOperation> _syncQueue = [];
  bool _isProcessingQueue = false;

  List<SyncOperation> get syncQueue => _syncQueue;
  int get pendingSyncCount => _syncQueue.length;
  bool get hasPendingSync => _syncQueue.isNotEmpty;
  bool get isProcessingQueue => _isProcessingQueue;

  bool _isSyncQueueLoaded = false;
  bool get isSyncQueueLoaded => _isSyncQueueLoaded;

  Future<void> _checkAndMigrateToSqlite() async {
    final prefs = await SharedPreferences.getInstance();
    final bool migrationDone = prefs.getBool('sqlite_migration_done') ?? false;
    
    if (migrationDone) return;

    debugPrint('Primeira inicialização após atualização. Limpando cache legado para iniciar modo usuário limpo...');
    
    for (var k in prefs.getKeys()) {
      if (k.startsWith('cache_')) {
        await prefs.remove(k);
      }
    }

    await prefs.setBool('sqlite_migration_done', true);
    debugPrint('Migração concluída com segurança.');
  }

  Future<void> loadSyncQueue({bool force = false}) async {
    if (_isSyncQueueLoaded && !force) return;
    try {
      _syncQueue = await _dbHelper.getSyncQueue();
      await purgeObsoleteSyncOperations();
    } catch (e) {
      debugPrint('Erro ao carregar fila de sync do SQLite: $e');
    }
    _isSyncQueueLoaded = true;
    _safeNotify();
  }

  /// Remove operações pendentes na fila que apontam para meses que não existem mais localmente no SQLite
  /// ou operações que já foram resolvidas localmente (como delete_month).
  Future<void> purgeObsoleteSyncOperations() async {
    try {
      final allMonths = await _dbHelper.getMonthsList();
      final initialCount = _syncQueue.length;
      _syncQueue.removeWhere((op) {
        // 1. Operações de delete_month não devem ficar na fila offline (o mês já não existe localmente)
        if (op.type == 'delete_month') {
          debugPrint('🧹 Purgando operação de delete_month da fila: ${op.month}');
          return true;
        }

        // 2. Renomeação de mês: válida se o novo nome ainda existir localmente
        if (op.type == 'rename_month') {
          final newTitle = op.payload['newTitle'] as String?;
          if (newTitle != null && allMonths.contains(newTitle)) {
            return false;
          }
        }

        // 3. Qualquer operação cujo mês não existe mais localmente no SQLite é obsoleta
        if (!allMonths.contains(op.month)) {
          debugPrint('🧹 Purgando operação de sync obsoleta para mês apagado: ${op.type} (${op.month})');
          return true;
        }

        return false;
      });

      if (_syncQueue.length != initialCount) {
        await _saveSyncQueue();
        if (_syncQueue.isEmpty) {
          _lastSyncError = null;
        }
        _safeNotify();
      }
    } catch (e) {
      debugPrint('Erro ao purgar operações obsoletas de sync: $e');
    }
  }

  /// Limpa toda a fila de sincronização offline sob demanda
  Future<void> clearSyncQueue() async {
    _syncQueue.clear();
    await _saveSyncQueue();
    _lastSyncError = null;
    _safeNotify();
  }

  Future<void> _saveSyncQueue() async {
    try {
      await _dbHelper.saveSyncQueue(_syncQueue);
    } catch (e) {
      debugPrint('Erro ao salvar fila de sync no SQLite: $e');
    }
  }

  void _enqueueOperation(String type, String month, Map<String, dynamic> payload) {
    if (!isSyncEnabled) {
      // Se a conta atual não sincroniza com o Sheets (offline, deslogado ou workspace não pessoal), não enfileira
      return;
    }
    if (type == 'delete_month') {
      // Deleções de mês na nuvem são executadas diretamente e não bloqueiam a fila offline
      return;
    }

    if (type == 'sync_items') {
      _syncQueue.removeWhere((op) => op.type == 'sync_items' && op.month == month);
    }
    
    _syncQueue.add(SyncOperation(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      month: month,
      payload: payload,
    ));
    _saveSyncQueue();
    _safeNotify();
    
    processSyncQueue();
  }

  Future<void> processSyncQueue() async {
    if (!isSyncEnabled) {
      debugPrint('Sincronização em nuvem desativada para a conta atual. Fila de sync pausada.');
      return;
    }
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    _safeNotify();

    try {
      while (_syncQueue.isNotEmpty) {
        final op = _syncQueue.first;
        debugPrint('Processando operação de sync offline: ${op.type} para o mês ${op.month}');
        
        // Se a operação for delete_month, descarta imediatamente
        if (op.type == 'delete_month') {
          debugPrint('🧹 Descartando delete_month da fila: ${op.month}');
          _syncQueue.removeAt(0);
          await _saveSyncQueue();
          _safeNotify();
          continue;
        }

        final allLocalMonths = await _dbHelper.getMonthsList();
        bool isMonthMissingLocally = !allLocalMonths.contains(op.month);
        if (op.type == 'rename_month') {
          final newTitle = op.payload['newTitle'] as String?;
          if (newTitle != null && allLocalMonths.contains(newTitle)) {
            isMonthMissingLocally = false;
          }
        }

        // Se o mês foi excluído localmente, descarta imediatamente qualquer operação pendente
        if (isMonthMissingLocally) {
          debugPrint('🧹 Descartando operação de sync para mês inexistente localmente: ${op.type} (${op.month})');
          _syncQueue.removeAt(0);
          await _saveSyncQueue();
          _safeNotify();
          continue;
        }
        
        try {
          if (op.type == 'sync_items') {
            final List<Item> items = await _dbHelper.getItems(op.month);
            await _service.overwriteAllItems(op.month, items);
          } else if (op.type == 'update_budget') {
            final double budgetValue = (op.payload['budget'] as num).toDouble();
            final previousMonth = _service.currentMonthTitle;
            if (previousMonth != op.month) {
              await _service.switchMonth(op.month);
            }
            await _service.updateBudget(budgetValue);
            if (previousMonth != op.month) {
              await _service.switchMonth(previousMonth);
            }
          } else if (op.type == 'create_month') {
            final title = op.payload['title'] as String;
            final useTemplate = op.payload['useTemplate'] as bool;
            final initialBudget = op.payload['initialBudget'] != null ? (op.payload['initialBudget'] as num).toDouble() : null;
            final sourceMonth = op.payload['sourceMonth'] as String?;
            await _service.createNewMonth(title, useTemplate, initialBudget: initialBudget, sourceMonth: sourceMonth);
          } else if (op.type == 'rename_month') {
            final oldTitle = op.payload['oldTitle'] as String;
            final newTitle = op.payload['newTitle'] as String;
            await _service.renameMonth(oldTitle, newTitle);
          } else if (op.type == 'finalize_month') {
            final isFinalized = op.payload['isFinalized'] as bool;
            final previousMonth = _service.currentMonthTitle;
            if (previousMonth != op.month) {
              await _service.switchMonth(op.month);
            }
            final summary = await _service.getSummaryOnly(op.month);
            await _service.updateSummary(
              op.month,
              summary['total'] ?? 0.0,
              summary['balance'] ?? 0.0,
              totalItems: (summary['totalItems'] ?? 0.0).toInt(),
              boughtItems: (summary['boughtItems'] ?? 0.0).toInt(),
              isFinalized: isFinalized,
            );
            if (previousMonth != op.month) {
              await _service.switchMonth(previousMonth);
            }
          }

          _syncQueue.removeAt(0);
          await _saveSyncQueue();
          _safeNotify();
        } catch (e) {
          final errStr = e.toString();
          final cleanErr = (errStr.contains('<!DOCTYPE html>') || errStr.toLowerCase().contains('<html'))
              ? 'FormatException: Resposta HTML inválida do Sheets API (portal captivo ou erro do servidor)'
              : errStr;
          
          final lowerErr = errStr.toLowerCase();
          // Se for erro permanente de aba inexistente, intervalo inválido ou requisição inválida, descarta a operação
          if (lowerErr.contains('not found') || 
              lowerErr.contains('não encontrada') || 
              lowerErr.contains('unable to parse range') || 
              lowerErr.contains('invalid request')) {
            debugPrint('Operação ${op.type} falhou com erro permanente no Sheets ($cleanErr). Descartando operação da fila.');
            _syncQueue.removeAt(0);
            await _saveSyncQueue();
            _safeNotify();
            continue;
          }

          debugPrint('Erro de conexão ao processar sync offline: $cleanErr. Pausando fila.');
          _lastSyncError = cleanErr;
          break;
        }
      }
      if (_syncQueue.isEmpty) {
        _lastSyncError = null;
      }
    } finally {
      _isProcessingQueue = false;
      _safeNotify();
    }
  }
  final UserSheetsService _service = UserSheetsService();

  Future<String?> getActiveSpreadsheetId() => _service.getActiveSpreadsheetId();
  Future<String?> getActiveSpreadsheetUrl() => _service.getActiveSpreadsheetUrl();
  Future<bool> shareSpreadsheetWithEmail(String email, {bool asWriter = true}) =>
      _service.shareSpreadsheetWithEmail(email, asWriter: asWriter);
  Future<String?> makeSpreadsheetPublicWithLink() => _service.makeSpreadsheetPublicWithLink();
  Future<bool> isUsingCustomSharedSpreadsheet() => _service.isUsingCustomSharedSpreadsheet();
  Future<void> restoreDefaultSpreadsheet() async {
    await resetToDefaultSpreadsheet();
  }
  Future<void> connectToSharedSpreadsheet(String rawUrlOrId) async {
    await setCustomSpreadsheet(rawUrlOrId);
  }
  final NotificationService _notificationService = NotificationService();
  
  /// Local memory cache for items indexed by month title.
  final Map<String, List<Item>> _itemsCache = {};

  /// List of items for the currently active month.
  List<Item> _items = [];
  
  /// List of all available month titles (worksheets).
  List<String> _months = [];
  
  /// Loading state for items list (only true when there is NO local data at all).
  bool _isLoading = false;

  /// Whether a background cloud sync is running (non-blocking, no UI overlay).
  bool _isSyncingBackground = false;
  
  /// Loading state for months list.
  bool _isMonthsLoading = false;
  
  /// Local cache for financial summaries (budget, total, etc.) indexed by month title.
  final Map<String, Map<String, double>> _cachedSummary = {};
  
  /// Comprehensive price history for all items encountered across all lists.
  Map<String, List<Map<String, dynamic>>> _priceHistoryCache = {};
  
  bool _isPreFetchingStats = false;
  bool _isSyncingSummaries = false;
  DateTime? _lastDashboardUpdate;
  DateTime? _lastSummarySync;
  DateTime? _lastPriceHistoryCloudSync;
  final Map<String, DateTime> _lastItemsSync = {};

  /// Reverse index from barcode to history entries for O(1) instant barcode lookup
  final Map<String, List<Map<String, dynamic>>> _barcodeToHistoryCache = {};
  final Map<String, String> _nameToBarcodeCache = {};

  /// Fast memoization cache for item price badges
  final Map<String, Map<String, dynamic>> _badgeInfoCache = {};

  /// Cache for month comparable integer keys
  static final Map<String, int> _monthComparableCache = {};

  /// Debounce timer for saving price history to SharedPreferences
  Timer? _savePriceHistoryTimer;
  
  /// List of user-defined essential items for quick import.
  List<String> _essentialItems = [];

  List<Item> get items => _items;
  List<String> get months => _months;

  @visibleForTesting
  void setMonthsForTesting(List<String> testMonths) {
    _months = List.from(testMonths);
  }

  /// Retorna as listas de carrinhos na ordem de criação decrescente (mais recentes criadas no topo).
  List<String> get sortedMonthsDescending => _months;

  /// Retorna as listas de carrinhos na ordem de criação crescente (mais antigas criadas no topo).
  List<String> get sortedMonthsAscending => List<String>.from(_months);
  bool get isLoading => _isLoading;
  bool get isSyncingBackground => _isSyncingBackground;
  bool get isMonthsLoading => _isMonthsLoading;
  bool get isSyncingSummaries => _isSyncingSummaries;
  Map<String, Map<String, double>> get cachedSummary => _cachedSummary;
  List<String> get essentialItems => _essentialItems;
  Map<String, List<Map<String, dynamic>>> get priceHistoryCache => _priceHistoryCache;

  bool isMonthFinalized(String month) => _cachedSummary[month]?['isFinalized'] == 1.0;
  bool get isCurrentMonthFinalized => isMonthFinalized(currentMonth);

  bool _hasExceededBudgetAlerted = false;

  /// Verifica se os gastos estouraram o orçamento e dispara o alerta apenas UMA vez.
  /// Novos itens adicionados posteriormente não disparam novos alertas repetidos.
  void _checkBudgetAlert(double newTotal, {bool force = false}) {
    final b = budget;
    if (b <= 0) return;

    final bool enabled = _animationSettings['enable_notifications'] ?? true;
    if (!enabled) return;

    final percent = newTotal / b;

    // Se o valor estiver abaixo do orçamento, reseta a flag para poder avisar novamente
    // caso o usuário remova itens e depois volte a ultrapassar o limite
    if (percent < 1.0) {
      _hasExceededBudgetAlerted = false;
      return;
    }

    // Só dispara se estourar o limite (>= 1.0) E se ainda NÃO tiver avisado neste ciclo
    if (percent >= 1.0 && (force || !_hasExceededBudgetAlerted)) {
      _hasExceededBudgetAlerted = true;
      final excedente = newTotal - b;
      final msg = excedente > 0
          ? 'Seus gastos (${Utils.formatCurrency(newTotal)}) ultrapassaram o orçamento de ${Utils.formatCurrency(b)} em ${Utils.formatCurrency(excedente)}.'
          : 'Seus gastos atingiram o limite do orçamento de ${Utils.formatCurrency(b)}.';
      _notificationService.showBudgetAlert('Limite Excedido!', msg);
    }
  }

  /// Updates local metrics and cache after a data change.
  void _updateLocalMetrics({Item? triggerItem, bool checkBudget = false}) async {
    final target = _service.currentMonthTitle;
    final total = totalCost;
    final b = budget;
    
    if (checkBudget && (triggerItem == null || triggerItem.quantity > 0)) {
      _checkBudgetAlert(total);
    }

    _updateNotification(); 

    final currentFinalized = _cachedSummary[target]?['isFinalized'] ?? 0.0;
    final newData = {
      'budget': b, 'total': total, 'balance': b - total,
      'totalItems': _items.fold(0.0, (s, it) => s + (it.isKg ? (it.quantity > 0 ? 1.0 : 0.0) : it.quantity)),
      'boughtItems': _items.where((it) => it.isBought).fold(0.0, (s, it) => s + (it.isKg ? (it.quantity > 0 ? 1.0 : 0.0) : it.quantity)),
      'isFinalized': currentFinalized,
    };

    if (target == realCurrentMonthName) _dashboardData = newData;
    _updateCacheForMonth(target, newData);
    QuickSummaryService.saveQuickSummary(
      month: target,
      totalSpent: total,
      budget: b,
      totalItems: _items.length,
      boughtItems: _items.where((it) => it.isBought).length,
    );
  }

  Map<String, dynamic>? findProductByBarcode(String barcode) {
    final cleanBarcode = Item.parseBarcode(barcode);
    if (cleanBarcode == null || cleanBarcode.isEmpty) return null;

    // 1. Procura na lista ativa
    for (var it in _items) {
      if (Item.parseBarcode(it.barcode) == cleanBarcode) {
        return {
          'name': it.name,
          'price': it.unitPrice,
          'category': it.category,
          'barcode': cleanBarcode,
          'isKg': it.isKg,
        };
      }
    }

    // 2. Procura em todos os meses em cache (preserva o nome original)
    for (var monthItems in _itemsCache.values) {
      for (var it in monthItems) {
        if (Item.parseBarcode(it.barcode) == cleanBarcode) {
          return {
            'name': it.name,
            'price': it.unitPrice,
            'category': it.category,
            'barcode': cleanBarcode,
            'isKg': it.isKg,
          };
        }
      }
    }

    // 3. Procura no cache de histórico de preços em O(1)
    if (_barcodeToHistoryCache.containsKey(cleanBarcode)) {
      final list = _barcodeToHistoryCache[cleanBarcode]!;
      if (list.isNotEmpty) {
        final entry = list.last;
        final String originalName = entry['name'] ?? '';
        return {
          'name': originalName, 
          'price': (entry['price'] as num?)?.toDouble() ?? 0.0,
          'category': entry['category'] ?? 'Outros',
          'barcode': cleanBarcode,
        };
      }
    }
    return null;
  }

  String? findBarcodeForProductName(String name) {
    if (name.trim().isEmpty) return null;
    final normalized = Utils.normalize(name);

    if (_nameToBarcodeCache.containsKey(normalized)) {
      final cached = _nameToBarcodeCache[normalized]!;
      return cached.isNotEmpty ? cached : null;
    }

    // 1. Procura na lista ativa
    for (var it in _items) {
      final b = Item.parseBarcode(it.barcode);
      if (b != null && b.isNotEmpty) {
        final norm = Utils.normalize(it.name);
        _nameToBarcodeCache[norm] = b;
        if (norm == normalized) return b;
      }
    }

    // 2. Procura no histórico de preços
    if (_priceHistoryCache.containsKey(normalized)) {
      final history = _priceHistoryCache[normalized]!;
      for (var entry in history.reversed) {
        final b = Item.parseBarcode(entry['barcode']);
        if (b != null && b.isNotEmpty) {
          _nameToBarcodeCache[normalized] = b;
          return b;
        }
      }
    }

    // 3. Procura em todos os meses em cache
    for (var list in _itemsCache.values) {
      for (var it in list) {
        final b = Item.parseBarcode(it.barcode);
        if (b != null && b.isNotEmpty) {
          final norm = Utils.normalize(it.name);
          _nameToBarcodeCache[norm] = b;
          if (norm == normalized) return b;
        }
      }
    }

    // Marca sentinela como vazio para que próximas buscas sejam O(1)
    _nameToBarcodeCache[normalized] = '';
    return null;
  }

  void _fillMissingBarcodesInCurrentItems({bool notify = true}) {
    bool changed = false;
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].barcode == null || _items[i].barcode!.trim().isEmpty) {
        final b = findBarcodeForProductName(_items[i].name);
        if (b != null && b.isNotEmpty) {
          _items[i] = _items[i].copyWith(barcode: b);
          changed = true;
        }
      }
    }
    if (changed) {
      final month = _service.currentMonthTitle;
      _dbHelper.saveItems(month, _items);
      _itemsCache[month] = List.from(_items);
      if (notify) _safeNotify();
    }
  }

  Future<void> loadEssentialItems() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'essential_items_$_userPrefsPrefix';
    if (!prefs.containsKey(key)) {
      _essentialItems = List<String>.from(defaultEssentialItems);
      await prefs.setStringList(key, _essentialItems);
    } else {
      _essentialItems = prefs.getStringList(key) ?? [];
    }
    _safeNotify();
  }

  Future<void> resetEssentialItemsToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'essential_items_$_userPrefsPrefix';
    _essentialItems = List<String>.from(defaultEssentialItems);
    await prefs.setStringList(key, _essentialItems);
    _safeNotify();
  }

  Future<void> toggleEssentialItem(String name) async {
    if (_essentialItems.contains(name)) {
      _essentialItems.remove(name);
    } else {
      _essentialItems.add(name);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('essential_items_$_userPrefsPrefix', _essentialItems);
    _safeNotify();
  }

  Future<void> importEssentials() async {
    if (_essentialItems.isEmpty) return;
    for (var name in _essentialItems) {
      if (!_items.any((it) => Utils.normalize(it.name) == Utils.normalize(name))) {
        final newItem = Item(
          name: name,
          quantity: 0,
          unitPrice: 0,
          category: 'Mercearia',
          isBought: false,
        );
        await addItem(newItem);
      }
    }
  }

  static const List<Map<String, dynamic>> barbecueTemplateItems = [
    {'name': 'Carvão Vegetal', 'category': 'Limpeza / Outros', 'isKg': false},
    {'name': 'Picanha / Fraldinha', 'category': 'Açougue', 'isKg': true},
    {'name': 'Linguiça Toscana', 'category': 'Açougue', 'isKg': true},
    {'name': 'Asa / Coração de Frango', 'category': 'Açougue', 'isKg': true},
    {'name': 'Pão de Alho', 'category': 'Padaria', 'isKg': false},
    {'name': 'Queijo Coalho', 'category': 'Laticínios', 'isKg': false},
    {'name': 'Cerveja', 'category': 'Bebidas', 'isKg': false},
    {'name': 'Refrigerante / Suco', 'category': 'Bebidas', 'isKg': false},
    {'name': 'Gelo', 'category': 'Bebidas', 'isKg': false},
    {'name': 'Sal Grosso', 'category': 'Mercearia', 'isKg': false},
    {'name': 'Farofa Pronta', 'category': 'Mercearia', 'isKg': false},
    {'name': 'Guardanapos / Descartáveis', 'category': 'Limpeza / Outros', 'isKg': false},
  ];

  Future<void> importTemplateItems(List<Map<String, dynamic>> templateList) async {
    for (var raw in templateList) {
      final name = raw['name'] as String;
      final category = (raw['category'] as String?) ?? 'Açougue';
      final isKg = (raw['isKg'] as bool?) ?? false;
      if (!_items.any((it) => Utils.normalize(it.name) == Utils.normalize(name))) {
        final newItem = Item(
          name: name,
          quantity: 1,
          unitPrice: 0,
          category: category,
          isKg: isKg,
          isBought: false,
        );
        await addItem(newItem);
      }
    }
  }

  Future<void> importSharedItems(
    List<Item> sharedItems, {
    bool replaceExisting = false,
    String? listTitle,
    double? newBudget,
  }) async {
    if (listTitle != null && listTitle.trim().isNotEmpty && listTitle != currentMonth) {
      if (!_months.contains(listTitle)) {
        await createNewMonth(listTitle, false);
      }
      await switchMonth(listTitle);
    }

    if (replaceExisting) {
      for (var it in List.from(_items)) {
        await removeItem(it.index);
      }
    }

    if (newBudget != null && newBudget > 0) {
      await updateBudget(newBudget);
    }

    for (var it in sharedItems) {
      if (!replaceExisting && _items.any((existing) => Utils.normalize(existing.name) == Utils.normalize(it.name))) {
        continue;
      }
      await addItem(it);
    }
    _safeNotify();
  }

  /// Retorna os itens em cache para um determinado mês/lista sem alterar o mês ativo
  List<Item>? getCachedItemsForMonth(String month) {
    if (month == currentMonth) return List.from(_items);
    if (_itemsCache.containsKey(month)) return List.from(_itemsCache[month]!);
    return null;
  }

  /// Busca os itens de um mês/lista específico de forma assíncrona (cache ou banco local)
  Future<List<Item>> getItemsForMonth(String month) async {
    if (month == currentMonth) return List.from(_items);
    if (_itemsCache.containsKey(month) && _itemsCache[month]!.isNotEmpty) {
      return List.from(_itemsCache[month]!);
    }
    try {
      final dbItems = await _dbHelper.getItems(month);
      if (dbItems.isNotEmpty) {
        _itemsCache[month] = dbItems;
        return List.from(dbItems);
      }
    } catch (_) {}
    return [];
  }

  /// Obtém ou cria uma planilha compartilhada exclusiva para uma lista específica
  Future<String?> getOrCreateDedicatedSpreadsheetForList(String listTitle) async {
    try {
      final items = await getItemsForMonth(listTitle);
      final listBudget = (listTitle == currentMonth) ? budget : 0.0;
      return await _service.createOrGetDedicatedSpreadsheetForList(listTitle, items, budget: listBudget);
    } catch (e) {
      debugPrint('Erro ao criar planilha dedicada para $listTitle: $e');
      return null;
    }
  }

  /// Retorna o ID da planilha dedicada da lista se existir
  Future<String?> getDedicatedSpreadsheetIdForList(String listTitle) =>
      _service.getSpreadsheetIdForMonth(listTitle);

  /// Importa a lista compartilhada associando à planilha dedicada dela
  Future<void> importSharedListWithSpreadsheet({
    required String title,
    required String? spreadsheetId,
    required List<Item> fallbackItems,
    double? budget,
  }) async {
    // 1. Cria a lista no app do outro usuário se ainda não existir
    if (!_months.contains(title)) {
      await createNewMonth(title, false, initialBudget: budget);
    }

    // 2. Se houver planilha compartilhada para esta lista, associa o ID exclusivamente a ela
    if (spreadsheetId != null && spreadsheetId.isNotEmpty) {
      await _service.setSpreadsheetIdForMonth(title, spreadsheetId);
    }

    // 3. Alterna para esta lista
    await switchMonth(title);

    // 4. SEMPRE carrega os itens recebidos no banco local e na memória primeiro!
    // Isso garante que o segundo celular exiba instantaneamente todos os produtos recebidos (0ms)
    await importSharedItems(fallbackItems, replaceExisting: true, listTitle: title, newBudget: budget);

    // 5. Se houver planilha dedicada e sincronização Google ativa, sincroniza em background
    if (spreadsheetId != null && spreadsheetId.isNotEmpty && isSyncEnabled) {
      _runBackgroundSync(title);
    }
    _safeNotify();
  }

  double get totalCost => _items.where((it) => it.isBought).fold(0.0, (sum, item) => sum + item.totalPrice);
  
  double get budget {
    final current = _service.currentMonthTitle;
    return _cachedSummary[current]?['budget'] ?? _service.budget;
  }
  
  double get totalFromSheet {
    final current = _service.currentMonthTitle;
    if (_items.isNotEmpty) return totalCost;
    return _cachedSummary[current]?['total'] ?? _service.totalFromSheet;
  }

  String get currentMonth => _service.currentMonthTitle;

  String? findVigentMonth(List<String> monthsList) {
    if (monthsList.isEmpty) return null;
    final now = DateTime.now();
    final monthsPt = [
      'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
      'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'
    ];
    final monthName = monthsPt[now.month - 1].toLowerCase();
    final monthAbbr = monthName.substring(0, 3);
    final yearFull = now.year.toString();
    final yearShort = yearFull.substring(2);
    final monthNum = now.month.toString().padLeft(2, '0');
    final monthNumShort = now.month.toString();
    
    final List<String> matches = [];
    for (var m in monthsList) {
      final norm = m.toLowerCase();
      bool isMatch = false;
      if (norm.contains(monthName) && (norm.contains(yearFull) || norm.contains(yearShort))) {
        isMatch = true;
      } else if (norm.contains(monthAbbr) && (norm.contains(yearFull) || norm.contains(yearShort))) {
        isMatch = true;
      } else if ((norm.contains('$monthNum/$yearFull') || norm.contains('$monthNum/$yearShort') ||
           norm.contains('$monthNum-$yearFull') || norm.contains('$monthNum-$yearShort') ||
           norm.contains('$monthNum $yearFull') || norm.contains('$monthNum $yearShort') ||
           norm.contains('$monthNum.$yearFull') || norm.contains('$monthNum.$yearShort') ||
           norm.contains('${monthNum}_$yearFull') || norm.contains('${monthNum}_$yearShort') ||
           norm.contains('$monthNum$yearFull') || norm.contains('$monthNum$yearShort'))) {
        isMatch = true;
      } else if ((norm.contains('$monthNumShort/$yearFull') || norm.contains('$monthNumShort/$yearShort') ||
           norm.contains('$monthNumShort-$yearFull') || norm.contains('$monthNumShort-$yearShort') ||
           norm.contains('$monthNumShort $yearFull') || norm.contains('$monthNumShort $yearShort') ||
           norm.contains('$monthNumShort.$yearFull') || norm.contains('$monthNumShort.$yearShort'))) {
        isMatch = true;
      } else if (norm == monthName || norm == monthAbbr) {
        isMatch = true;
      }
      
      if (isMatch) {
        matches.add(m);
      }
    }
    
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first;
    
    // If multiple matches, prioritize the one that has items in summaries
    for (var m in matches) {
      final summary = _cachedSummary[m];
      if (summary != null && (summary['totalItems'] ?? 0.0) > 0) {
        return m;
      }
    }
    
    // Otherwise, prefer current month if it's in matches
    if (matches.contains(currentMonth)) {
      return currentMonth;
    }
    
    return matches.first;
  }

  String get realCurrentMonthName {
    // 1. Prioriza encontrar o mês vigente do calendário atual (ex: Outubro 2026)
    final matched = findVigentMonth(_months);
    if (matched != null) return matched;
    
    // 2. Se não houver correspondente exato ao calendário, usa o último mês criado (mais recente)
    if (_months.isNotEmpty) {
      return _months.last;
    }
    
    // 3. Se o mês ativo for válido e estiver na lista, usa ele
    if (currentMonth.isNotEmpty && _months.contains(currentMonth)) {
      return currentMonth;
    }
    
    // 4. Fallback final para o mês corrente do calendário
    final now = DateTime.now();
    final monthsPt = [
      'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
      'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'
    ];
    return '${monthsPt[now.month - 1]} ${now.year}';
  }

  Map<String, double> _dashboardData = {'budget': 0.0, 'total': 0.0, 'balance': 0.0, 'totalItems': 0.0, 'boughtItems': 0.0};
  Map<String, double> get dashboardData => _dashboardData;

  Future<void> _loadDashboardData({bool force = false}) async {
    final currentName = realCurrentMonthName;
    
    // Se o mês atual não existir na lista de carrinhos ativos, zera o painel e não sincroniza
    final bool hasMonth = _months.contains(currentName);
    if (!hasMonth) {
      _dashboardData = {
        'budget': 0.0,
        'total': 0.0,
        'balance': 0.0,
        'totalItems': 0.0,
        'boughtItems': 0.0,
      };
      _safeNotify();
      if (force || _lastSummarySync == null || DateTime.now().difference(_lastSummarySync!).inMinutes >= 5) {
        _getAllMonthsSummary(force: force);
      }
      return;
    }
    
    try {
      final summaries = await _dbHelper.getMonthsSummaries();
      if (summaries.containsKey(currentName)) {
        _dashboardData = summaries[currentName]!;
        _safeNotify();
      }
    } catch (e) {
      debugPrint('Erro ao ler dashboard do SQLite: $e');
    }

    if (!force && _lastDashboardUpdate != null && 
        DateTime.now().difference(_lastDashboardUpdate!).inMinutes < 5) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await _syncDashboardCloud(currentName, prefs);
    _getAllMonthsSummary(force: force);
  }

  Future<void> loadDashboardData({bool force = false}) async {
    await initialization;
    await _loadDashboardData(force: force);
  }


  Future<void> _syncDashboardCloud(String target, SharedPreferences prefs) async {
    if (!isSyncEnabled) return;
    if (!_isSyncQueueLoaded) {
      await loadSyncQueue();
    }

    if (_syncQueue.any((op) => op.month == target)) {
      debugPrint('Sync de dashboard evitado para o mês $target: existem operações pendentes na fila.');
      return;
    }

    // Se o mês não existe em _months, aborta a sincronização para evitar criar cache fantasma
    if (!_months.contains(target)) {
      debugPrint('Sync de dashboard abortado: o mês $target não existe em _months.');
      return;
    }

    try {
      final summary = await _service.getSummaryOnly(target);
      
      if (_syncQueue.any((op) => op.month == target)) {
        debugPrint('Sync de dashboard descartado para o mês $target: nova operação pendente na fila.');
        return;
      }

      final newData = {
        'budget': summary['budget'] ?? 0.0, 
        'total': summary['total'] ?? 0.0,
        'balance': summary['balance'] ?? 0.0,
        'totalItems': summary['totalItems'] ?? 0.0,
        'boughtItems': summary['boughtItems'] ?? 0.0,
        'isFinalized': summary['isFinalized'] ?? _cachedSummary[target]?['isFinalized'] ?? 0.0,
      };

      if (target == realCurrentMonthName) {
        _dashboardData = newData;
        _lastDashboardUpdate = DateTime.now();
      }

      _updateCacheForMonth(target, newData);
      _lastSyncError = null;
      _safeNotify();
    } catch (e) {
      final errStr = e.toString();
      final cleanErr = (errStr.contains('<!DOCTYPE html>') || errStr.toLowerCase().contains('<html'))
          ? 'FormatException: Resposta HTML inválida do Sheets API (portal captivo ou erro do servidor)'
          : errStr;
      debugPrint('Erro Sync Dashboard: $cleanErr');
      _lastSyncError = cleanErr;
      _safeNotify();
    }
  }

  void _updateCacheForMonth(String month, Map<String, double> data) async {
    _cachedSummary[month] = data;
    try {
      await _dbHelper.updateMonthSummary(month, data);
    } catch (e) {
      debugPrint('Erro ao atualizar resumo do mês no SQLite: $e');
    }
  }

  static const List<String> categories = [
    'Hortifruti', 'Açougue e Frios', 'Padaria', 'Laticínios e Refrigerados',
    'Mercearia', 'Congelados e Prontos', 'Bebidas', 'Limpeza',
    'Higiene Pessoal', 'Utilidades', 'Outros'
  ];

  static const Map<String, String> categoryEmojis = {
    'Hortifruti': '🍎', 'Açougue e Frios': '🥩', 'Padaria': '🍞',
    'Laticínios e Refrigerados': '🥛', 'Mercearia': '🛒', 'Congelados e Prontos': '❄️',
    'Bebidas': '🥤', 'Limpeza': '🧼', 'Higiene Pessoal': '🪥', 'Utilidades': '🛠️', 'Outros': '📦',
  };

  static final Map<String, String> _smartCategories = {
    'arroz': 'Mercearia', 'feijao': 'Mercearia', 'feijão': 'Mercearia', 'macarrao': 'Mercearia', 'macarrão': 'Mercearia', 'oleo': 'Mercearia', 'óleo': 'Mercearia', 'sal': 'Mercearia', 'acucar': 'Mercearia', 'açúcar': 'Mercearia', 'cafe': 'Mercearia', 'café': 'Mercearia', 'farinha': 'Mercearia', 'extrato': 'Mercearia', 'molho': 'Mercearia', 'milho': 'Mercearia', 'azeite': 'Mercearia', 'biscoito': 'Mercearia', 'bolacha': 'Mercearia', 'atum': 'Mercearia', 'sardinha': 'Mercearia', 'maionese': 'Mercearia', 'ervilha': 'Mercearia',
    'banana': 'Hortifruti', 'maca': 'Hortifruti', 'maçã': 'Hortifruti', 'laranja': 'Hortifruti', 'limao': 'Hortifruti', 'limão': 'Hortifruti', 'tomate': 'Hortifruti', 'cebola': 'Hortifruti', 'alho': 'Hortifruti', 'batata': 'Hortifruti', 'cenoura': 'Hortifruti', 'alface': 'Hortifruti', 'couve': 'Hortifruti', 'repolho': 'Hortifruti', 'melancia': 'Hortifruti', 'mamao': 'Hortifruti', 'mamão': 'Hortifruti', 'uva': 'Hortifruti', 'pimentao': 'Hortifruti', 'pimentão': 'Hortifruti', 'cheiro verde': 'Hortifruti', 'coentro': 'Hortifruti',
    'carne': 'Açougue e Frios', 'frango': 'Açougue e Frios', 'peixe': 'Açougue e Frios', 'porco': 'Açougue e Frios', 'bife': 'Açougue e Frios', 'picanha': 'Açougue e Frios', 'alcatra': 'Açougue e Frios', 'coxao': 'Açougue e Frios', 'patinho': 'Açougue e Frios', 'file': 'Açougue e Frios', 'filé': 'Açougue e Frios', 'peito': 'Açougue e Frios', 'coxa': 'Açougue e Frios', 'asa': 'Açougue e Frios', 'linguica': 'Açougue e Frios', 'linguiça': 'Açougue e Frios', 'salsicha': 'Açougue e Frios', 'hamburguer': 'Açougue e Frios', 'hambúrguer': 'Açougue e Frios', 'bacon': 'Açougue e Frios', 'presunto': 'Açougue e Frios', 'mortadela': 'Açougue e Frios', 'salame': 'Açougue e Frios',
    'pao': 'Padaria', 'pão': 'Padaria', 'bolo': 'Padaria', 'torta': 'Padaria', 'salgado': 'Padaria', 'pao de queijo': 'Padaria', 'baguete': 'Padaria', 'bisnaga': 'Padaria', 'rosca': 'Padaria',
    'refrigerante': 'Bebidas', 'suco': 'Bebidas', 'agua': 'Bebidas', 'água': 'Bebidas', 'cerveja': 'Bebidas', 'vinho': 'Bebidas', 'vodka': 'Bebidas', 'energetico': 'Bebidas', 'energético': 'Bebidas', 'cha': 'Bebidas', 'chá': 'Bebidas', 'guarana': 'Bebidas', 'guaraná': 'Bebidas', 'coca': 'Bebidas',
    'sabao': 'Limpeza', 'sabão': 'Limpeza', 'detergente': 'Limpeza', 'amaciante': 'Limpeza', 'desinfetante': 'Limpeza', 'agua sanitaria': 'Limpeza', 'água sanitária': 'Limpeza', 'cloro': 'Limpeza', 'esponja': 'Limpeza', 'bucha': 'Limpeza', 'rodo': 'Limpeza', 'vassoura': 'Limpeza', 'pano': 'Limpeza', 'saco de lixo': 'Limpeza', 'inseticida': 'Limpeza', 'alcool': 'Limpeza', 'álcool': 'Limpeza',
    'papel higienico': 'Higiene Pessoal', 'papel higiênico': 'Higiene Pessoal', 'sabonete': 'Higiene Pessoal', 'shampoo': 'Higiene Pessoal', 'condicionador': 'Higiene Pessoal', 'creme dental': 'Higiene Pessoal', 'pasta de dente': 'Higiene Pessoal', 'escova': 'Higiene Pessoal', 'fio dental': 'Higiene Pessoal', 'desodorante': 'Higiene Pessoal', 'absorvente': 'Higiene Pessoal', 'laminas': 'Higiene Pessoal', 'barbeador': 'Higiene Pessoal', 'algodao': 'Higiene Pessoal', 'algodão': 'Higiene Pessoal', 'cotonete': 'Higiene Pessoal',
    'pizza': 'Congelados e Prontos', 'lasanha': 'Congelados e Prontos', 'nuggets': 'Congelados e Prontos', 'batata frita': 'Congelados e Prontos', 'sorvete': 'Congelados e Prontos', 'pao de queijo congelado': 'Congelados e Prontos', 'empadao': 'Congelados e Prontos',
    'leite': 'Laticínios e Refrigerados', 'queijo': 'Laticínios e Refrigerados', 'mussarela': 'Laticínios e Refrigerados', 'prato': 'Laticínios e Refrigerados', 'manteiga': 'Laticínios e Refrigerados', 'margarina': 'Laticínios e Refrigerados', 'iogurte': 'Laticínios e Refrigerados', 'requeijao': 'Laticínios e Refrigerados', 'requeijão': 'Laticínios e Refrigerados', 'creme de leite': 'Laticínios e Refrigerados', 'leite condensado': 'Laticínios e Refrigerados', 'danone': 'Laticínios e Refrigerados', 'yakult': 'Laticínios e Refrigerados',
    'pilha': 'Utilidades', 'lampada': 'Utilidades', 'lâmpada': 'Utilidades', 'fita': 'Utilidades', 'isopor': 'Utilidades', 'vela': 'Utilidades', 'fosforo': 'Utilidades', 'fósforo': 'Utilidades'
  };

  static String suggestCategoryForName(String name) {
    if (name.trim().isEmpty) return 'Outros';
    String normalized = Utils.normalize(name);
    for (var entry in _smartCategories.entries) {
      if (normalized.contains(entry.key)) return entry.value;
    }
    return 'Mercearia'; 
  }

  void _safeNotify() {
    if (!hasListeners) return;
    Future.microtask(notifyListeners);
  }

  Timer? _notificationDebounceTimer;
  void _updateNotification() {
    _notificationDebounceTimer?.cancel();
    _notificationDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      final bool enabled = _animationSettings['enable_notifications'] ?? true;
      if (!enabled) {
        _notificationService.cancelProgress();
        return;
      }

      final int total = _items.length;
      final int bought = _items.where((it) => it.isBought).length;
      final double totalPrice = totalCost;

      if (total > 0) {
        _notificationService.showOrUpdateProgress(
          _service.currentMonthTitle, 
          bought, 
          total, 
          totalPrice,
          budget: budget,
        );
      } else {
        _notificationService.cancelProgress();
      }
    });
  }

  void refreshNotification() {
    _updateNotification();
  }

  void cancelAllNotifications() {
    _notificationService.cancelAll();
  }

  final Map<String, Future<void>?> _activeItemsSync = {};

  Future<void> _loadItems({bool force = false}) async {
    final String targetMonth = _service.currentMonthTitle;
    debugPrint('🔍 _loadItems: targetMonth="$targetMonth", force=$force, isSyncEnabled=$isSyncEnabled, cacheKeys=${_itemsCache.keys.toList()}');
    
    // 1. Check memory cache first — instant, synchronous return
    if (_itemsCache.containsKey(targetMonth) && !force) {
      final wasAlreadyLoaded = identical(_items, _itemsCache[targetMonth]!);
      _items = _itemsCache[targetMonth]!;
      debugPrint('🔍 _loadItems: HIT memory cache → ${_items.length} itens');
      _isLoading = false;
      for (var it in _items) {
        final bc = Item.parseBarcode(it.barcode);
        if (bc != null && bc.isNotEmpty) {
          _nameToBarcodeCache[Utils.normalize(it.name)] = bc;
        }
      }
      if (!wasAlreadyLoaded) {
        _safeNotify();
      }
      _updateNotification();
      
      final lastSync = _lastItemsSync[targetMonth];
      final bool isStale = lastSync == null ? false : DateTime.now().difference(lastSync).inMinutes > 5;
      _lastItemsSync.putIfAbsent(targetMonth, () => DateTime.now());
      if (!isStale) {
        return;
      }
      // Cache is stale — sync in background without blocking UI
      _runBackgroundSync(targetMonth);
      return;
    }
    
    // 2. Check SQLite for local data
    bool hasLocalData = false;
    try {
      final localItems = await _dbHelper.getItems(targetMonth);
      debugPrint('🔍 _loadItems: SQLite retornou ${localItems.length} itens para "$targetMonth"');
      if (localItems.isNotEmpty) {
        _items = localItems;
        _itemsCache[targetMonth] = localItems;
        _lastItemsSync[targetMonth] = DateTime.now();
        hasLocalData = true;
        _isLoading = false; 
        for (var it in localItems) {
          final bc = Item.parseBarcode(it.barcode);
          if (bc != null && bc.isNotEmpty) {
            _nameToBarcodeCache[Utils.normalize(it.name)] = bc;
          }
        }
        final prefs = await SharedPreferences.getInstance();
        _updatePriceHistoryWithItemList(localItems, targetMonth, prefs);
        _fillMissingBarcodesInCurrentItems(notify: false);
        _safeNotify();
        _updateNotification();
      }
    } catch (e) {
      debugPrint('Erro ao ler itens do SQLite: $e');
    }
    
    // 3. If no local data at all, show the blocking loader
    if (!hasLocalData) {
      debugPrint('🔍 _loadItems: SEM dados locais para "$targetMonth". isSyncEnabled=$isSyncEnabled');
      _items = [];
      if (!isSyncEnabled) {
        _isLoading = false;
        _safeNotify();
        return;
      }
      _isLoading = true;
      _safeNotify();
      
      // Must await sync — user has nothing to see yet
      try {
        if (_activeItemsSync.containsKey(targetMonth)) {
          await _activeItemsSync[targetMonth];
        } else {
          final syncFuture = _syncItemsCloudBackground(targetMonth);
          _activeItemsSync[targetMonth] = syncFuture;
          await syncFuture;
        }
      } finally {
        _activeItemsSync.remove(targetMonth);
        _isLoading = false;
        _safeNotify();
      }
      return;
    }
    
    // 4. Has local data — sync in background without blocking
    if (force) {
      // Pull-to-refresh: await so caller knows when it's done
      await _runBackgroundSyncAwaitable(targetMonth);
    } else {
      _runBackgroundSync(targetMonth);
    }
  }

  Future<void> loadItems({bool force = false}) async {
    await initialization;
    await _loadItems(force: force);
  }

  /// Runs cloud sync in the background without blocking the UI.
  /// Used when local data is already displayed.
  void _runBackgroundSync(String targetMonth) {
    if (_activeItemsSync.containsKey(targetMonth)) return; // Already syncing
    
    _isSyncingBackground = true;
    _safeNotify();
    
    final syncFuture = _syncItemsCloudBackground(targetMonth);
    _activeItemsSync[targetMonth] = syncFuture;
    
    syncFuture.whenComplete(() {
      _activeItemsSync.remove(targetMonth);
      _isSyncingBackground = false;
      _safeNotify();
    });
  }

  /// Awaitable version of background sync for pull-to-refresh.
  Future<void> _runBackgroundSyncAwaitable(String targetMonth) async {
    if (_activeItemsSync.containsKey(targetMonth)) {
      await _activeItemsSync[targetMonth];
      return;
    }
    
    _isSyncingBackground = true;
    _safeNotify();
    
    try {
      final syncFuture = _syncItemsCloudBackground(targetMonth);
      _activeItemsSync[targetMonth] = syncFuture;
      await syncFuture;
    } finally {
      _activeItemsSync.remove(targetMonth);
      _isSyncingBackground = false;
      _safeNotify();
    }
  }

  Future<void> _syncItemsCloudBackground(String target) async {
    if (!isSyncEnabled) return;
    if (!_isSyncQueueLoaded) {
      await loadSyncQueue();
    }

    if (_syncQueue.any((op) => op.month == target)) {
      debugPrint('Sync de itens evitado para o mês $target: existem operações pendentes na fila.');
      return;
    }

    try {
      final freshItems = await _service.getItems(title: target);
      
      if (_syncQueue.any((op) => op.month == target)) {
        debugPrint('Sync de itens descartado para o mês $target: nova operação pendente na fila.');
        return;
      }

      final localCachedItems = await _dbHelper.getItems(target);

      if (freshItems.isEmpty && localCachedItems.isNotEmpty) {
        debugPrint('Aba na nuvem está vazia para o mês $target, mas local possui ${localCachedItems.length} itens. Sincronizando itens locais para a nuvem.');
        await _service.overwriteAllItems(target, localCachedItems);
        _lastItemsSync[target] = DateTime.now();
        _updateLocalMetrics();
        _dbHelper.saveLocalBackupSnapshot();
      } else {
        List<Item> mergedItems = freshItems;
        bool pushedLocalExtras = false;
        if (localCachedItems.length > freshItems.length) {
          final cloudNames = freshItems.map((e) => Utils.normalize(e.name)).toSet();
          final missingFromCloud = localCachedItems.where((loc) => !cloudNames.contains(Utils.normalize(loc.name))).toList();
          if (missingFromCloud.isNotEmpty) {
            mergedItems = [...freshItems, ...missingFromCloud];
            for (int i = 0; i < mergedItems.length; i++) {
              mergedItems[i] = mergedItems[i].copyWith(index: i + 7);
            }
            pushedLocalExtras = true;
          }
        }
        if (target == _service.currentMonthTitle) {
          _items = mergedItems;
          _itemsCache[target] = mergedItems;
          _lastItemsSync[target] = DateTime.now();
        }
        await _dbHelper.saveItems(target, mergedItems);
        _itemsCache[target] = mergedItems;
        final prefs = await SharedPreferences.getInstance();
        _updatePriceHistoryWithItemList(mergedItems, target, prefs);
        _updateLocalMetrics();
        _dbHelper.saveLocalBackupSnapshot();
        if (pushedLocalExtras) {
          _service.overwriteAllItems(target, mergedItems).catchError((e) {
            debugPrint('Aviso ao sincronizar itens locais mesclados para a nuvem ($target): $e');
          });
        }
      }
      _lastSyncError = null;
      _safeNotify();
    } catch (e) {
      final errStr = e.toString();
      final cleanErr = (errStr.contains('<!DOCTYPE html>') || errStr.toLowerCase().contains('<html'))
          ? 'FormatException: Resposta HTML inválida do Sheets API (portal captivo ou erro do servidor)'
          : errStr;
      debugPrint('Erro Sync Background: $cleanErr');
      _lastSyncError = cleanErr;
      _safeNotify();
    }
  }

  Future<void> _pushMissingLocalMonthToCloud(String monthTitle) async {
    if (!isSyncEnabled || DatabaseHelper.isDummySheetName(monthTitle)) return;
    try {
      final localItems = await _dbHelper.getItems(monthTitle);
      final details = await _dbHelper.getMonthDetails(monthTitle);
      final budget = (details?['budget'] as num?)?.toDouble();
      await _service.createNewMonth(monthTitle, false, initialBudget: budget);
      if (localItems.isNotEmpty) {
        await _service.overwriteAllItems(monthTitle, localItems);
      }
      debugPrint('☁️ Mês local "$monthTitle" (${localItems.length} itens) sincronizado com Google Sheets.');
    } catch (e) {
      debugPrint('Aviso ao enviar mês local "$monthTitle" para Google Sheets: $e');
    }
  }

  Future<void> _loadMonths() async {
    List<String> localMonths = [];
    try {
      await _dbHelper.recalculateAllMonthSummaries();
      localMonths = await _dbHelper.getMonthsByWorkspace(_currentWorkspace);
      debugPrint('🔍 _loadMonths: SQLite retornou ${localMonths.length} meses para workspace "$_currentWorkspace": $localMonths');
      _months = List.from(localMonths);
      final summaries = await _dbHelper.getMonthsSummaries();
      debugPrint('🔍 _loadMonths: summaries keys=${summaries.keys.toList()}');
      _cachedSummary.addAll(summaries);
      _safeNotify();
    } catch (e) {
      debugPrint('Erro ao carregar meses do SQLite: $e');
    }
    if (!isSyncEnabled) return;

    // Sincronização de planilhas via Google Sheets só se aplica ao workspace pessoal
    if (_currentWorkspace != 'personal') {
      debugPrint('🔍 _loadMonths: Workspace "$_currentWorkspace" mantido localmente.');
      return;
    }

    if (_isMonthsLoading) return;
    _isMonthsLoading = true;
    _safeNotify();
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final deletedList = prefs.getStringList('explicitly_deleted_months') ?? const <String>[];
      final Set<String> explicitlyDeleted = deletedList.map((e) => e.trim().toLowerCase()).toSet();

      // Carrega abas da planilha no Google Sheets filtrando abas fantasmas e excluídas
      final rawFetched = await _service.getAvailableMonths();
      final fetchedMonths = rawFetched
          .where((m) => !DatabaseHelper.isDummySheetName(m) && !explicitlyDeleted.contains(m.trim().toLowerCase()))
          .toList();

      // Mescla de forma NÃO-DESTRUTIVA: preserva listas locais e adiciona novas listas da nuvem
      final localPersonalMonths = await _dbHelper.getMonthsByWorkspace('personal');
      final List<String> mergedMonths = [];
      final Set<String> seenLower = {};

      final List<String> missingInCloud = [];
      // 1. Preserva estritamente a ordem de criação local das listas
      for (final m in localPersonalMonths) {
        final key = m.trim().toLowerCase();
        if (DatabaseHelper.isDummySheetName(m) || explicitlyDeleted.contains(key)) continue;
        if (seenLower.add(key)) {
          mergedMonths.add(m);
          if (!fetchedMonths.any((f) => f.trim().toLowerCase() == key)) {
            missingInCloud.add(m);
          }
        }
      }

      // 2. Adiciona ao final apenas listas novas criadas externamente na nuvem
      for (final m in fetchedMonths) {
        final key = m.trim().toLowerCase();
        if (seenLower.add(key)) {
          mergedMonths.add(m);
        }
      }

      _months = mergedMonths;
      if (_months.isNotEmpty) {
        await _dbHelper.saveMonthsList(_months);
      }

      // Envia para o Google Sheets em background qualquer lista local que ainda não exista na planilha
      for (final missingMonth in missingInCloud) {
        _pushMissingLocalMonthToCloud(missingMonth);
      }

      await purgeObsoleteSyncOperations();

      // Load summaries
      final allSummaries = await _dbHelper.getMonthsSummaries();
      _cachedSummary.addAll(allSummaries);

      // Se o mês atual estiver na lista ativa, carrega seu resumo para o dashboard, senão zera o painel
      final currentName = realCurrentMonthName;
      if (_months.contains(currentName)) {
        if (_cachedSummary.containsKey(currentName)) {
          _dashboardData = _cachedSummary[currentName]!;
        }
      } else {
        _dashboardData = {
          'budget': 0.0,
          'total': 0.0,
          'balance': 0.0,
          'totalItems': 0.0,
          'boughtItems': 0.0,
        };
      }
      _lastSyncError = null;
    } catch (e) {
      debugPrint('Erro ao sincronizar meses com Google Sheets: $e');
      _lastSyncError = e.toString();
    } finally {
      _isMonthsLoading = false;
      _safeNotify();
    }
  }

  Future<void> loadMonths() async {
    await initialization;
    await _loadMonths();
  }

  Future<void> _switchMonth(String month) async {
    debugPrint('🔍 _switchMonth: month="$month", cacheHit=${_itemsCache.containsKey(month)}, cacheSize=${_itemsCache[month]?.length ?? -1}');
    _badgeInfoCache.clear();
    _hasExceededBudgetAlerted = false;
    // Update items list synchronously using memory cache if available to prevent lag or flashing
    if (_itemsCache.containsKey(month)) {
      _items = _itemsCache[month]!;
      _isLoading = false;
    } else {
      try {
        final local = await _dbHelper.getItems(month);
        if (local.isNotEmpty) {
          _items = local;
          _itemsCache[month] = local;
          _isLoading = false;
        } else {
          _items = [];
          _isLoading = true;
        }
      } catch (_) {
        _items = [];
        _isLoading = true;
      }
    }
    _safeNotify();
    _updateNotification();

    _service.setCurrentTitle(month);
    
    try {
      final summaries = await _dbHelper.getMonthsSummaries();
      if (summaries.containsKey(month)) {
        _cachedSummary[month] = summaries[month]!;
      }
    } catch (e) {
      debugPrint('Erro ao ler resumo no switchMonth: $e');
    }

    await _loadItems();
    await loadMonthMetadata(month);
    detectNearbySupermarket(notify: false);
    
    final hasPendingCreate = _syncQueue.any((op) => op.type == 'create_month' && op.month == month);
    if (isSyncEnabled && !hasPendingCreate) {
      _service.init(title: month).catchError((e) {
        debugPrint('Erro ao inicializar GSheets para o mês $month em switchMonth: $e');
      });
    } else {
      debugPrint('Inicialização do GSheets evitada em switchMonth para o mês $month: criação ainda pendente ou sincronização desativada.');
    }
  }

  Future<void> switchMonth(String month) async {
    await initialization;
    await _switchMonth(month);
  }

  Future<void> createNewMonth(
    String title, 
    bool useTemplate, 
    {double? initialBudget, String? purpose, String? workspace}
  ) async {
    await initialization;
    String sourceMonth = '';
    final activeWs = workspace ?? _currentWorkspace;
    final activePurpose = purpose ?? 'geral';

    // Se o mês estava marcado como excluído anteriormente, remove da lista de excluídos
    try {
      final prefs = await SharedPreferences.getInstance();
      final deleted = prefs.getStringList('explicitly_deleted_months') ?? <String>[];
      if (deleted.any((e) => e.trim().toLowerCase() == title.trim().toLowerCase())) {
        deleted.removeWhere((e) => e.trim().toLowerCase() == title.trim().toLowerCase());
        await prefs.setStringList('explicitly_deleted_months', deleted);
      }
    } catch (_) {}
    
    if (!_months.contains(title)) {
      _months.add(title);
      _itemsCache[title] = []; // Initialize empty memory cache
      _currentMonthPurpose = activePurpose;
      
      final initialData = {
        'budget': initialBudget ?? 0.0,
        'total': 0.0,
        'balance': initialBudget ?? 0.0,
        'totalItems': 0.0,
        'boughtItems': 0.0,
      };
      _cachedSummary[title] = initialData;
      
      try {
        await _dbHelper.insertMonth(
          title,
          budget: initialBudget ?? 0.0,
          total: 0.0,
          balance: initialBudget ?? 0.0,
          totalItems: 0.0,
          boughtItems: 0.0,
          purpose: activePurpose,
          workspace: activeWs,
        );
      } catch (e) {
        debugPrint('Erro ao criar mês no SQLite: $e');
      }

      if (useTemplate) {
        sourceMonth = _service.currentMonthTitle;
        List<Item> sourceItems = [];
        
        // 1. Tenta pegar itens do mês atual
        if (sourceMonth.isNotEmpty && _months.contains(sourceMonth)) {
          sourceItems = await _dbHelper.getItems(sourceMonth);
        }

        // 2. Se o atual estiver vazio, busca o mês mais recente (de trás para frente) que tenha itens
        if (sourceItems.isEmpty) {
          debugPrint('🔍 createNewMonth: Mês atual "$sourceMonth" está vazio. Buscando alternativa...');
          for (var m in _months.reversed) {
            if (m != title && m != sourceMonth) {
              final items = await _dbHelper.getItems(m);
              if (items.isNotEmpty) {
                sourceMonth = m;
                sourceItems = items;
                debugPrint('🔍 createNewMonth: Usando "$m" como template alternativo (${items.length} itens)');
                break;
              }
            }
          }
        }
        
        if (sourceItems.isNotEmpty) {
          try {
            final List<Item> templateItems = [];
            int nextIndex = 7;
            for (var it in sourceItems) {
              templateItems.add(Item(
                index: nextIndex++,
                name: it.name,
                quantity: 0,
                unitPrice: 0,
                isKg: it.isKg,
                category: it.category,
                isBought: false,
                barcode: it.barcode,
              ));
            }
            await _dbHelper.saveItems(title, templateItems);
            _itemsCache[title] = templateItems; // Save to memory cache
          } catch (e) {
            debugPrint('Erro ao decodificar template do mês anterior localmente no SQLite: $e');
          }
        }
      }

      _dbHelper.saveLocalBackupSnapshot();
      _safeNotify();
    }
    
    _enqueueOperation('create_month', title, {
      'title': title,
      'useTemplate': useTemplate,
      'initialBudget': initialBudget,
      'sourceMonth': sourceMonth,
    });
    
    await _switchMonth(title);
  }

  Future<void> renameMonth(String oldTitle, String newTitle) async {
    await initialization;
    final idx = _months.indexOf(oldTitle);
    if (idx != -1) {
      _months[idx] = newTitle;
      
      try {
        await _dbHelper.renameMonth(oldTitle, newTitle);
        if (_itemsCache.containsKey(oldTitle)) {
          _itemsCache[newTitle] = _itemsCache.remove(oldTitle)!;
        }
        _dbHelper.saveLocalBackupSnapshot();
      } catch (e) {
        debugPrint('Erro ao renomear mês no SQLite: $e');
      }
      
      if (_cachedSummary.containsKey(oldTitle)) {
        _cachedSummary[newTitle] = _cachedSummary.remove(oldTitle)!;
      }
      
      if (_service.currentMonthTitle == oldTitle) {
        _service.setCurrentTitle(newTitle);
      }
      _safeNotify();
    }
    
    _enqueueOperation('rename_month', oldTitle, {
      'oldTitle': oldTitle,
      'newTitle': newTitle,
    });
  }

  Future<void> deleteMonth(String title) async {
    await initialization;
    // Registra a exclusão explícita pelo usuário para que a recuperação automática respeite a decisão
    try {
      final prefs = await SharedPreferences.getInstance();
      final deleted = prefs.getStringList('explicitly_deleted_months') ?? <String>[];
      if (!deleted.any((e) => e.trim().toLowerCase() == title.trim().toLowerCase())) {
        deleted.add(title.trim());
        await prefs.setStringList('explicitly_deleted_months', deleted);
      }
      final rawSnap = prefs.getString('local_backup_carts_v1');
      if (rawSnap != null && rawSnap.isNotEmpty) {
        final decoded = jsonDecode(rawSnap);
        if (decoded is Map<String, dynamic> && decoded.remove(title.trim()) != null) {
          await prefs.setString('local_backup_carts_v1', jsonEncode(decoded));
        }
      }
    } catch (_) {}

    // Purgar qualquer operação pendente na fila para este mês excluído
    _syncQueue.removeWhere((op) => op.month == title);
    await _saveSyncQueue();

    if (_months.contains(title)) {
      _months.remove(title);
      
      try {
        await _dbHelper.deleteMonth(title);
        _itemsCache.remove(title);
      } catch (e) {
        debugPrint('Erro ao deletar mês no SQLite: $e');
      }
      
      _cachedSummary.remove(title);
      
      if (_service.currentMonthTitle == title && _months.isNotEmpty) {
        final target = findVigentMonth(_months) ?? _months.last;
        await _switchMonth(target);
      }
      _safeNotify();
    }
    
    // Se a sincronização com a nuvem estiver ativa, dispara a exclusão no Google Sheets sem travar a fila offline
    if (isSyncEnabled) {
      try {
        _service.deleteMonth(title).catchError((e) {
          debugPrint('Aviso ao excluir aba "$title" no Google Sheets: $e');
        });
      } catch (e) {
        debugPrint('Erro ao invocar deleteMonth no Google Sheets: $e');
      }
    }
  }

  Future<void> finalizeMonth(String month, {bool finalize = true}) async {
    await initialization;
    try {
      final summary = _cachedSummary[month] ?? {'budget': 0.0, 'total': 0.0, 'balance': 0.0, 'totalItems': 0.0, 'boughtItems': 0.0};
      summary['isFinalized'] = finalize ? 1.0 : 0.0;
      await _dbHelper.updateMonthSummary(month, summary);
    } catch (e) {
      debugPrint('Erro ao finalizar mês no SQLite: $e');
    }
    _safeNotify();
    
    _enqueueOperation('finalize_month', month, {'isFinalized': finalize});

    // Compartilha automaticamente todas as compras do mês finalizado com a comunidade
    if (finalize) {
      if (month == _service.currentMonthTitle) {
        _notificationService.cancelProgress();
      }
      CommunityPriceService.instance.syncMonthPurchases(month, _items).catchError((e) {
        debugPrint('Erro ao sincronizar compras do carrinho finalizado: $e');
      });
    }
  }

  Future<void> updateBudget(double newBudget) async {
    await initialization;
    final month = _service.currentMonthTitle;
    if (isMonthFinalized(month)) {
      debugPrint('Erro: Tentativa de editar orçamento de um mês finalizado.');
      return;
    }
    try {
      final summary = _cachedSummary[month] ?? {'budget': 0.0, 'total': 0.0, 'balance': 0.0, 'totalItems': 0.0, 'boughtItems': 0.0};
      summary['budget'] = newBudget;
      summary['balance'] = newBudget - (summary['total'] ?? 0.0);
      await _dbHelper.updateMonthSummary(month, summary);
    } catch (e) {
      debugPrint('Erro ao atualizar orçamento no SQLite: $e');
    }
    _updateLocalMetrics(checkBudget: true);
    _safeNotify();
    
    _enqueueOperation('update_budget', month, {'budget': newBudget});
  }

  Future<void> addItem(Item item) async {
    await initialization;
    final month = _service.currentMonthTitle;
    if (isMonthFinalized(month)) {
      debugPrint('Erro: Tentativa de adicionar item em um mês finalizado.');
      return;
    }
    
    final String? effectiveBarcode = (item.barcode != null && item.barcode!.trim().isNotEmpty)
        ? item.barcode!.trim()
        : findBarcodeForProductName(item.name);
    
    final String? effectiveSupermarket = (item.supermarket != null && item.supermarket!.trim().isNotEmpty)
        ? item.supermarket!.trim()
        : (_selectedSupermarketFilter ?? _detectedSupermarket?['name']);

    final nextIndex = _items.isEmpty ? 7 : (_items.last.index ?? 6) + 1;
    final newItem = Item(
      index: nextIndex,
      name: item.name,
      quantity: item.quantity,
      unitPrice: item.unitPrice,
      isKg: item.isKg,
      category: item.category,
      isBought: item.isBought,
      barcode: effectiveBarcode,
      supermarket: effectiveSupermarket,
    );
    
    _items.add(newItem);
    _updateLocalMetrics(triggerItem: newItem, checkBudget: true);
    
    final prefs = await SharedPreferences.getInstance();
    _addOrUpdatePriceHistoryCache(newItem, month, prefs);
    
    try {
      await _dbHelper.saveItems(month, _items);
      _itemsCache[month] = List.from(_items);
      _dbHelper.saveLocalBackupSnapshot();
    } catch (e) {
      debugPrint('Erro ao salvar item adicionado no SQLite: $e');
    }

    // Compartilha obrigatoriamente e de forma automática na base da comunidade
    if (newItem.unitPrice > 0) {
      final market = (newItem.supermarket != null && newItem.supermarket!.trim().isNotEmpty)
          ? newItem.supermarket!.trim()
          : (_selectedSupermarketFilter ?? _detectedSupermarket?['name'] ?? CommunityPriceService.defaultStoreName);
      final lat = (_detectedSupermarket?['latitude'] as num?)?.toDouble() ?? 
          (market == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLat : null);
      final lng = (_detectedSupermarket?['longitude'] as num?)?.toDouble() ?? 
          (market == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLng : null);

      CommunityPriceService.instance.publishPrice(
        productName: newItem.name,
        price: newItem.unitPrice,
        supermarketName: market,
        category: newItem.category,
        unit: newItem.isKg ? 'kg' : 'un',
        latitude: lat,
        longitude: lng,
        submittedBy: _activeUserDisplayName,
        verifiedReceipt: false,
        createdAt: DatabaseHelper.parseDateFromMonthTitle(month),
      ).catchError((_) => false);
    }
    
    _safeNotify();
    
    _enqueueOperation('sync_items', month, {});
  }

  Future<void> updateItem(Item item) async {
    await initialization;
    final month = _service.currentMonthTitle;
    if (isMonthFinalized(month)) {
      debugPrint('Erro: Tentativa de atualizar item em um mês finalizado.');
      return;
    }
    final idx = _items.indexWhere((it) => it.index == item.index);
    if (idx != -1) {
      final String? effectiveBarcode = (item.barcode != null && item.barcode!.trim().isNotEmpty)
          ? item.barcode!.trim()
          : findBarcodeForProductName(item.name);
      final String? effectiveSupermarket = (item.supermarket != null && item.supermarket!.trim().isNotEmpty)
          ? item.supermarket!.trim()
          : (_selectedSupermarketFilter ?? _detectedSupermarket?['name']);
      final updatedItem = item.copyWith(
        barcode: effectiveBarcode,
        supermarket: effectiveSupermarket,
      );

      _items[idx] = updatedItem;
      _updateLocalMetrics(triggerItem: updatedItem, checkBudget: true);
      
      final prefs = await SharedPreferences.getInstance();
      _addOrUpdatePriceHistoryCache(updatedItem, month, prefs);
      
      try {
        await _dbHelper.saveItems(month, _items);
        _itemsCache[month] = List.from(_items);
        _dbHelper.saveLocalBackupSnapshot();
      } catch (e) {
        debugPrint('Erro ao atualizar item no SQLite: $e');
      }

      // Compartilha obrigatoriamente e de forma automática na base da comunidade
      if (updatedItem.unitPrice > 0) {
        final market = (updatedItem.supermarket != null && updatedItem.supermarket!.trim().isNotEmpty)
            ? updatedItem.supermarket!.trim()
            : (_selectedSupermarketFilter ?? _detectedSupermarket?['name'] ?? CommunityPriceService.defaultStoreName);
        final lat = (_detectedSupermarket?['latitude'] as num?)?.toDouble() ?? 
            (market == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLat : null);
        final lng = (_detectedSupermarket?['longitude'] as num?)?.toDouble() ?? 
            (market == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLng : null);

        CommunityPriceService.instance.publishPrice(
          productName: updatedItem.name,
          price: updatedItem.unitPrice,
          supermarketName: market,
          category: updatedItem.category,
          unit: updatedItem.isKg ? 'kg' : 'un',
          latitude: lat,
          longitude: lng,
          submittedBy: _activeUserDisplayName,
          verifiedReceipt: false,
          createdAt: DatabaseHelper.parseDateFromMonthTitle(month),
        ).catchError((_) => false);
      }
      
      _safeNotify();
      
      _enqueueOperation('sync_items', month, {});
    }
  }

  Future<void> removeItem(int index) async {
    await initialization;
    final month = _service.currentMonthTitle;
    if (isMonthFinalized(month)) {
      debugPrint('Erro: Tentativa de remover item de um mês finalizado.');
      return;
    }
    _items.removeWhere((it) => it.index == index);
    
    for (var i = 0; i < _items.length; i++) {
      _items[i] = Item(
        index: i + 7,
        name: _items[i].name,
        quantity: _items[i].quantity,
        unitPrice: _items[i].unitPrice,
        isKg: _items[i].isKg,
        category: _items[i].category,
        isBought: _items[i].isBought,
        barcode: _items[i].barcode,
      );
    }
    
    _updateLocalMetrics(checkBudget: true);
    
    try {
      await _dbHelper.saveItems(month, _items);
      _itemsCache[month] = List.from(_items);
      _dbHelper.saveLocalBackupSnapshot();
    } catch (e) {
      debugPrint('Erro ao remover item no SQLite: $e');
    }
    
    _safeNotify();
    
    _enqueueOperation('sync_items', month, {});
  }

  Future<void> toggleBought(Item item) async {
    await initialization;
    final month = _service.currentMonthTitle;
    if (isMonthFinalized(month)) {
      debugPrint('Erro: Tentativa de marcar item como comprado em um mês finalizado.');
      return;
    }
    item.isBought = !item.isBought;
    _updateLocalMetrics(triggerItem: item, checkBudget: true);
    
    final prefs = await SharedPreferences.getInstance();
    if (item.isBought) {
      _addOrUpdatePriceHistoryCache(item, month, prefs);
    }
    
    try {
      await _dbHelper.saveItems(month, _items);
      _itemsCache[month] = List.from(_items);
      _dbHelper.saveLocalBackupSnapshot();
    } catch (e) {
      debugPrint('Erro ao salvar status comprado no SQLite: $e');
    }
    
    _safeNotify();
    
    _enqueueOperation('sync_items', month, {});
  }

  Map<String, double>? getCachedSummaryForMonth(String month) {
    return _cachedSummary[month];
  }

  void _mergePriceHistory(Map<String, List<Map<String, dynamic>>> sourceHistory) {
    for (var entry in sourceHistory.entries) {
      final normalized = entry.key;
      final sourceList = entry.value;
      final targetList = _priceHistoryCache.putIfAbsent(normalized, () => []);
      for (var sourceItem in sourceList) {
        final month = sourceItem['month'] as String? ?? '';
        final existingIdx = targetList.indexWhere((e) => e['month'] == month);
        if (existingIdx != -1) {
          final existing = targetList[existingIdx];
          final cleanBc = Item.parseBarcode(sourceItem['barcode'] as String? ?? '') ?? '';
          final existingBc = Item.parseBarcode(existing['barcode'] as String? ?? '') ?? '';
          final price = (sourceItem['price'] as num?)?.toDouble() ?? 0.0;
          final existingPrice = (existing['price'] as num?)?.toDouble() ?? 0.0;

          if (existingBc.isEmpty && cleanBc.isNotEmpty) {
            existing['barcode'] = cleanBc;
          }
          if (existingPrice <= 0 && price > 0) {
            existing['price'] = price;
          }
          if ((existing['name'] as String? ?? '').isEmpty && (sourceItem['name'] as String? ?? '').isNotEmpty) {
            existing['name'] = sourceItem['name'];
          }
          _indexEntryByBarcode(existing);
        } else {
          final copy = Map<String, dynamic>.from(sourceItem);
          targetList.add(copy);
          _indexEntryByBarcode(copy);
        }
      }
    }
    _badgeInfoCache.clear();
  }

  void _indexEntryByBarcode(Map<String, dynamic> entry) {
    final bc = Item.parseBarcode(entry['barcode'] as String? ?? '');
    final name = entry['name'] as String? ?? '';
    if (bc != null && bc.isNotEmpty) {
      if (name.isNotEmpty) {
        _nameToBarcodeCache[Utils.normalize(name)] = bc;
      }
      final list = _barcodeToHistoryCache.putIfAbsent(bc, () => []);
      final month = entry['month'] as String? ?? '';
      final existingIdx = list.indexWhere((e) => e['month'] == month);
      if (existingIdx != -1) {
        list[existingIdx] = entry;
      } else {
        list.add(entry);
      }
    }
  }

  void _rebuildBarcodeIndex() {
    _barcodeToHistoryCache.clear();
    _nameToBarcodeCache.clear();
    for (var list in _priceHistoryCache.values) {
      for (var entry in list) {
        _indexEntryByBarcode(entry);
      }
    }
    for (var it in _items) {
      final bc = Item.parseBarcode(it.barcode);
      if (bc != null && bc.isNotEmpty) {
        _nameToBarcodeCache[Utils.normalize(it.name)] = bc;
      }
    }
  }

  int _parseMonthYearComparable(String monthStr) {
    final cached = _monthComparableCache[monthStr];
    if (cached != null) return cached;

    final norm = Utils.normalize(monthStr).toLowerCase();
    int year = 0;
    final yearMatch = RegExp(r'\b(20\d\d)\b').firstMatch(norm);
    if (yearMatch != null) {
      year = int.tryParse(yearMatch.group(1)!) ?? 0;
    } else {
      final yearMatch2 = RegExp(r'/(\d{2,4})\b').firstMatch(norm);
      if (yearMatch2 != null) {
        int y = int.tryParse(yearMatch2.group(1)!) ?? 0;
        year = y < 100 ? 2000 + y : y;
      }
    }

    const monthMap = {
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

    int month = 0;
    for (var entry in monthMap.entries) {
      if (norm.contains(entry.key)) {
        month = entry.value;
        break;
      }
    }

    if (month == 0) {
      final numMatch = RegExp(r'\b(\d{1,2})[/.-]').firstMatch(norm);
      if (numMatch != null) {
        final m = int.tryParse(numMatch.group(1)!) ?? 0;
        if (m >= 1 && m <= 12) month = m;
      }
    }

    // Se encontrou o mês mas não o ano, assume o ano atual
    if (year == 0 && month > 0) {
      year = DateTime.now().year;
    }

    final int res = (year > 0 && month > 0) ? (year * 100 + month) : 0;

    _monthComparableCache[monthStr] = res;
    return res;
  }

  void _scheduleSavePriceHistory() {
    _savePriceHistoryTimer?.cancel();
    _savePriceHistoryTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cache_price_history_v2_$_userPrefsPrefix', jsonEncode(_priceHistoryCache));
      } catch (e) {
        debugPrint('Erro ao salvar cache de histórico de preços: $e');
      }
    });
  }

  void _addOrUpdatePriceHistoryEntry(Item item, String month) {
    if (item.name.trim().isEmpty) return;
    final normalized = Utils.normalize(item.name);
    
    final history = _priceHistoryCache.putIfAbsent(normalized, () => []);
    
    final existingIdx = history.indexWhere((entry) => entry['month'] == month);
    final cleanBarcode = Item.parseBarcode(item.barcode) ?? '';
    final entryData = {
      'name': item.name.trim(),
      'month': month,
      'price': item.unitPrice,
      'category': item.category,
      'barcode': cleanBarcode,
      'supermarket': item.supermarket,
    };
    if (existingIdx != -1) {
      if ((entryData['barcode'] as String).isEmpty && (history[existingIdx]['barcode'] as String? ?? '').isNotEmpty) {
        entryData['barcode'] = history[existingIdx]['barcode'];
      }
      if (entryData['price'] == 0 && (history[existingIdx]['price'] as num? ?? 0) > 0) {
        entryData['price'] = history[existingIdx]['price'];
      }
      if (entryData['supermarket'] == null && history[existingIdx]['supermarket'] != null) {
        entryData['supermarket'] = history[existingIdx]['supermarket'];
      }
      history[existingIdx] = entryData;
      _indexEntryByBarcode(entryData);
    } else {
      history.add(entryData);
      _indexEntryByBarcode(entryData);
    }
  }

  void _invalidateBadgeCacheForItem(String name) {
    _badgeInfoCache.removeWhere((key, _) => key.startsWith('${name}_'));
  }

  void _addOrUpdatePriceHistoryCache(Item item, String month, [SharedPreferences? prefs]) {
    _addOrUpdatePriceHistoryEntry(item, month);
    _invalidateBadgeCacheForItem(item.name);
    _scheduleSavePriceHistory();
  }

  void _updatePriceHistoryWithItemList(List<Item> itemsList, String monthTitle, [SharedPreferences? prefs]) {
    bool hasUpdates = false;
    for (var it in itemsList) {
      if (it.name.trim().isNotEmpty && (it.unitPrice > 0 || (it.barcode != null && it.barcode!.trim().isNotEmpty))) {
        _addOrUpdatePriceHistoryEntry(it, monthTitle);
        hasUpdates = true;
      }
    }
    if (hasUpdates) {
      _badgeInfoCache.clear();
      _scheduleSavePriceHistory();
    }
  }

  Future<void> _loadFullPriceHistory({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Carrega do SharedPreferences em memória rapidamente
    if (_priceHistoryCache.isEmpty) {
      final cachedJson = prefs.getString('cache_price_history_v2_$_userPrefsPrefix');
      if (cachedJson != null) {
        try {
          final Map<String, dynamic> decoded = jsonDecode(cachedJson);
          _priceHistoryCache = decoded.map((key, value) {
            final list = (value as List).map((item) => Map<String, dynamic>.from(item)).toList();
            return MapEntry(key, list);
          });
          _rebuildBarcodeIndex();
          _safeNotify();
        } catch (e) {
          debugPrint('Erro ao decodificar cache de histórico de preços: $e');
        }
      }
    }

    // 2. Carrega do banco SQLite local e mescla (garante dados locais offline instantâneos)
    try {
      final sqliteHistory = await _dbHelper.getAllPriceHistory();
      if (sqliteHistory.isNotEmpty) {
        _mergePriceHistory(sqliteHistory);
        _rebuildBarcodeIndex();
        _safeNotify();
      }
    } catch (e) {
      debugPrint('Erro ao carregar histórico de preços do SQLite: $e');
    }

    if (!isSyncEnabled) {
      debugPrint('Sincronização desativada para a conta atual. Histórico carregado a partir do SQLite local.');
      return;
    }

    // Throttle de 5 minutos para consulta da nuvem, a menos que seja forçado
    if (!force && _lastPriceHistoryCloudSync != null && DateTime.now().difference(_lastPriceHistoryCloudSync!).inMinutes < 5) {
      return;
    }

    _syncPriceHistoryCloudBackground(force: force);
  }

  void _syncPriceHistoryCloudBackground({bool force = false}) async {
    if (!isSyncEnabled || _isPreFetchingStats) return;
    _isPreFetchingStats = true;
    _safeNotify();
    try {
      final freshHistory = await _service.getFullPriceHistory();
      if (freshHistory.isNotEmpty) {
        _mergePriceHistory(freshHistory);
        _rebuildBarcodeIndex();
        _lastPriceHistoryCloudSync = DateTime.now();
        _scheduleSavePriceHistory();
        _fillMissingBarcodesInCurrentItems();
      }
      _lastSyncError = null;
    } catch (e) {
      final errStr = e.toString();
      final cleanErr = (errStr.contains('<!DOCTYPE html>') || errStr.toLowerCase().contains('<html'))
          ? 'FormatException: Resposta HTML inválida do Sheets API (portal captivo ou erro do servidor)'
          : errStr;
      debugPrint('Erro ao buscar histórico de preços da nuvem: $cleanErr');
      _lastSyncError = cleanErr;
    } finally {
      _isPreFetchingStats = false;
      _safeNotify();
    }
  }

  Future<void> loadFullPriceHistory({bool force = false}) async {
    await initialization;
    await _loadFullPriceHistory(force: force);
  }

  /// Retorna o histórico de preços completo para um produto, combinando busca por nome e código de barras
  List<Map<String, dynamic>> getPriceHistorySync(String itemName, {String? barcode, bool sorted = false}) {
    if (itemName.trim().isEmpty && (barcode == null || barcode.trim().isEmpty)) {
      return [];
    }

    final normalizedName = Utils.normalize(itemName);
    final cleanBarcode = Item.parseBarcode(barcode) ?? (barcode != null ? barcode.trim() : '');

    final List<Map<String, dynamic>> matchedEntries = [];

    // 1. Busca pelo nome normalizado em O(1)
    if (normalizedName.isNotEmpty && _priceHistoryCache.containsKey(normalizedName)) {
      matchedEntries.addAll(_priceHistoryCache[normalizedName]!);
    }

    // 2. Identifica o barcode caso não tenha sido explicitamente fornecido
    String effectiveBarcode = cleanBarcode;
    if (effectiveBarcode.isEmpty && normalizedName.isNotEmpty) {
      final foundBc = findBarcodeForProductName(itemName);
      if (foundBc != null && foundBc.isNotEmpty) {
        effectiveBarcode = foundBc;
      }
    }

    // 3. Busca por código de barras em O(1) através do índice reverso
    if (effectiveBarcode.isNotEmpty && _barcodeToHistoryCache.containsKey(effectiveBarcode)) {
      matchedEntries.addAll(_barcodeToHistoryCache[effectiveBarcode]!);
    }

    if (matchedEntries.isEmpty) return [];

    // 4. Deduplica por mês preservando preço positivo e barcode
    final Map<String, Map<String, dynamic>> byMonth = {};
    for (var entry in matchedEntries) {
      final month = entry['month'] as String? ?? '';
      if (month.isEmpty) continue;

      final normMonth = Utils.normalize(month);
      if (!byMonth.containsKey(normMonth)) {
        byMonth[normMonth] = Map<String, dynamic>.from(entry);
      } else {
        final existing = byMonth[normMonth]!;
        final price = (entry['price'] as num?)?.toDouble() ?? 0.0;
        final existingPrice = (existing['price'] as num?)?.toDouble() ?? 0.0;
        if (existingPrice <= 0 && price > 0) {
          existing['price'] = price;
        }
        final bc = Item.parseBarcode(entry['barcode'] as String? ?? '') ?? '';
        if ((existing['barcode'] as String? ?? '').isEmpty && bc.isNotEmpty) {
          existing['barcode'] = bc;
        }
      }
    }

    final result = byMonth.values.toList();

    // 5. Ordena cronologicamente apenas se solicitado (ex: visualização no modal de histórico)
    if (sorted && result.length > 1) {
      result.sort((a, b) {
        final keyA = _parseMonthYearComparable(a['month'] as String? ?? '');
        final keyB = _parseMonthYearComparable(b['month'] as String? ?? '');
        return keyA.compareTo(keyB);
      });
    }

    return result;
  }

  /// Retorna o status ("Caro", "Barato", "Na Média", "Histórico", "Novo") e cor do badge para um item
  Map<String, dynamic> getPriceBadgeInfo(Item item) {
    final cacheKey = '${item.name}_${item.barcode}_${item.unitPrice}_$currentMonth';
    final cached = _badgeInfoCache[cacheKey];
    if (cached != null) return cached;

    final history = getPriceHistorySync(item.name, barcode: item.barcode, sorted: false);
    if (history.isEmpty) {
      final res = {'status': 'Novo', 'color': Colors.blueGrey, 'history': history};
      _badgeInfoCache[cacheKey] = res;
      return res;
    }

    // Considera apenas outros meses com preço positivo para comparação
    final currentNorm = Utils.normalize(currentMonth);
    final otherEntries = history.where((h) {
      final mNorm = Utils.normalize(h['month'] as String? ?? '');
      final p = (h['price'] as num?)?.toDouble() ?? 0.0;
      return mNorm != currentNorm && p > 0;
    }).toList();

    final comparisonEntries = otherEntries.isNotEmpty 
        ? otherEntries 
        : history.where((h) => ((h['price'] as num?)?.toDouble() ?? 0.0) > 0).toList();

    if (comparisonEntries.isEmpty) {
      final res = {'status': 'Novo', 'color': Colors.blueGrey, 'history': history};
      _badgeInfoCache[cacheKey] = res;
      return res;
    }

    double sum = 0;
    int count = 0;
    for (var h in comparisonEntries) {
      final p = (h['price'] as num?)?.toDouble() ?? 0.0;
      if (p > 0) {
        sum += p;
        count++;
      }
    }

    Map<String, dynamic> res;
    if (count == 0 || item.unitPrice <= 0) {
      if (count > 0 && item.unitPrice <= 0) {
        res = {'status': 'Histórico', 'color': Colors.blueGrey, 'history': history};
      } else {
        res = {'status': 'Novo', 'color': Colors.blueGrey, 'history': history};
      }
    } else {
      final avg = sum / count;
      if (item.unitPrice > avg * 1.1) {
        res = {'status': 'Caro', 'color': Colors.redAccent, 'history': history};
      } else if (item.unitPrice < avg * 0.9) {
        res = {'status': 'Barato', 'color': Colors.green, 'history': history};
      } else {
        res = {'status': 'Na Média', 'color': Colors.green, 'history': history};
      }
    }

    _badgeInfoCache[cacheKey] = res;
    return res;
  }

  Future<Map<String, Map<String, double>>> _getAllMonthsSummary({bool force = false}) async {
    if (!isSyncEnabled) return _cachedSummary;
    if (!force && _lastSummarySync != null && DateTime.now().difference(_lastSummarySync!).inMinutes < 5) {
      return _cachedSummary;
    }

    if (!_isSyncQueueLoaded) {
      await loadSyncQueue();
    }

    _isSyncingSummaries = true;
    _lastSummarySync = DateTime.now();
    try {
      final summaries = await _service.getBatchSummaries(_months);
      for (var entry in summaries.entries) {
        final m = entry.key;
        final s = entry.value;
        if (!_syncQueue.any((op) => op.month == m)) {
          _updateCacheForMonth(m, s);
        } else {
          debugPrint('Sync de resumo evitado para o mês $m no lote: existem operações pendentes na fila.');
        }
      }
      _lastSyncError = null;
      _safeNotify();
    } catch (e) {
      final errStr = e.toString();
      final cleanErr = (errStr.contains('<!DOCTYPE html>') || errStr.toLowerCase().contains('<html'))
          ? 'FormatException: Resposta HTML inválida do Sheets API (portal captivo ou erro do servidor)'
          : errStr;
      debugPrint('Erro ao obter resumos dos meses: $cleanErr');
      _lastSyncError = cleanErr;
      _safeNotify();
    } finally {
      _isSyncingSummaries = false;
    }
    return _cachedSummary;
  }

  Future<Map<String, Map<String, double>>> getAllMonthsSummary({bool force = false}) async {
    await initialization;
    return _getAllMonthsSummary(force: force);
  }

  Map<String, bool> _animationSettings = {'list_animations': true, 'gauge_animations': true, 'chart_animations': true, 'enable_notifications': true};
  Map<String, bool> get animationSettings => _animationSettings;
  double _defaultBudget = 0.0;
  double get defaultBudget => _defaultBudget;

  Future<void> loadAnimationSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _animationSettings = {
      'list_animations': prefs.getBool('anim_list') ?? true,
      'gauge_animations': prefs.getBool('anim_gauge') ?? true,
      'chart_animations': prefs.getBool('anim_chart') ?? true,
      'enable_notifications': prefs.getBool('enable_notifications') ?? true,
    };
    _defaultBudget = prefs.getDouble('settings_default_budget_$_userPrefsPrefix') ?? 0.0;
    _safeNotify();
  }

  Future<void> updateAnimationSetting(String key, bool value) async {
    _animationSettings[key] = value;
    final prefs = await SharedPreferences.getInstance();
    final map = {'list_animations': 'anim_list', 'gauge_animations': 'anim_gauge', 'chart_animations': 'anim_chart', 'enable_notifications': 'enable_notifications'};
    if (map.containsKey(key)) await prefs.setBool(map[key]!, value);
    if (key == 'enable_notifications') {
      if (!value) {
        _notificationService.cancelAll();
      } else {
        await _notificationService.requestPermissions();
        _updateNotification();
      }
    }
    _safeNotify();
  }

  Future<void> updateDefaultBudget(double value) async {
    _defaultBudget = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('settings_default_budget_$_userPrefsPrefix', value);
    _safeNotify();
  }

  Future<void> clearAllCache() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Limpeza profunda das SharedPreferences para chaves de dados do usuário ativo
    final keysToRemove = [
      'essential_items_$_userPrefsPrefix',
      'settings_default_budget_$_userPrefsPrefix',
      'cache_price_history_v2_$_userPrefsPrefix',
      'dashboard_card_order_$_userPrefsPrefix',
    ];
    for (var key in keysToRemove) {
      await prefs.remove(key);
    }
    
    // Reset the Sheets Service internal ID to prevent data leak between users
    _service.reset();

    try {
      await _dbHelper.clearAll();
    } catch (e) {
      debugPrint('Erro ao limpar SQLite: $e');
    }

    // Reset das variáveis locais e de sincronização
    _syncQueue.clear();
    _activeItemsSync.clear();
    _lastItemsSync.clear();
    _isProcessingQueue = false;
    _isSyncQueueLoaded = false;
    _lastDashboardUpdate = null;
    _lastSummarySync = null;
    _isLoading = false;
    _isSyncingBackground = false;
    _isMonthsLoading = false;
    _isPreFetchingStats = false;
    _isSyncingSummaries = false;

    _essentialItems = [];
    _defaultBudget = 0.0;
    _cachedSummary.clear();
    _priceHistoryCache.clear();
    _barcodeToHistoryCache.clear();
    _nameToBarcodeCache.clear();
    _badgeInfoCache.clear();
    _itemsCache.clear();
    _items = [];
    _months = [];

    _dashboardData = {
      'budget': 0.0,
      'total': 0.0,
      'balance': 0.0,
      'totalItems': 0.0,
      'boughtItems': 0.0,
    };

    _safeNotify();
  }

  // ==========================================
  // --- Módulo: Mercados & GPS (Supermarkets) ---
  // ==========================================

  Future<void> loadSupermarkets() async {
    try {
      _supermarkets = await _dbHelper.getSupermarkets();
      _safeNotify();
    } catch (e) {
      debugPrint('Erro ao carregar supermercados: $e');
    }
  }

  Future<int> addOrUpdateSupermarket({
    required String name,
    double? latitude,
    double? longitude,
    double radiusMeters = 200.0,
    String icon = 'store',
    String colorHex = '#1E88E5',
  }) async {
    double? lat = latitude;
    double? lng = longitude;
    if (lat == null || lng == null) {
      try {
        final pos = await LocationService.instance.getCurrentPosition();
        if (pos != null) {
          lat = pos.latitude;
          lng = pos.longitude;
        }
      } catch (_) {}
    }

    final id = await _dbHelper.saveSupermarket(
      name: name,
      latitude: lat,
      longitude: lng,
      radiusMeters: radiusMeters,
      icon: icon,
      colorHex: colorHex,
    );
    await loadSupermarkets();
    return id;
  }

  Future<void> deleteSupermarket(int id) async {
    await _dbHelper.deleteSupermarket(id);
    await loadSupermarkets();
  }

  Future<void> deleteSupermarketByName(String name) async {
    await _dbHelper.deleteSupermarketByName(name);
    await loadSupermarkets();
  }

  Future<void> detectNearbySupermarket({bool notify = false}) async {
    if (_isDetectingLocation) return;
    _isDetectingLocation = true;
    if (notify) _safeNotify();

    try {
      if (_supermarkets.isEmpty) {
        await loadSupermarkets();
      }
      final position = await LocationService.instance.getCurrentPosition();
      if (position != null) {
        final found = await LocationService.instance.identifyNearbySupermarket(position, _supermarkets);
        _detectedSupermarket = found;
      } else {
        _detectedSupermarket = null;
      }
    } catch (e) {
      debugPrint('Silently ignored GPS detection error: $e');
      _detectedSupermarket = null;
    } finally {
      _isDetectingLocation = false;
      _safeNotify();
    }
  }

  void setSupermarketFilter(String? marketName) {
    _selectedSupermarketFilter = marketName;
    _safeNotify();
  }

  void clearSupermarketFilter() {
    _selectedSupermarketFilter = null;
    _safeNotify();
  }

  // ==========================================
  // --- Módulo: Metadados do Mês & Finalidade ---
  // ==========================================

  Future<void> loadMonthMetadata(String monthTitle) async {
    try {
      final details = await _dbHelper.getMonthDetails(monthTitle);
      if (details != null) {
        _currentMonthPurpose = (details['purpose'] as String?) ?? 'geral';
        final ws = details['workspace'] as String?;
        if (ws != null && ws.isNotEmpty) {
          _currentWorkspace = ws;
        }
        final capsJson = details['category_caps'] as String?;
        if (capsJson != null && capsJson.isNotEmpty) {
          final Map<String, dynamic> decoded = jsonDecode(capsJson);
          _categoryCaps = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
        } else {
          _categoryCaps = {};
        }
      } else {
        _currentMonthPurpose = 'geral';
        _categoryCaps = {};
      }
      _safeNotify();
    } catch (e) {
      debugPrint('Erro ao carregar metadados do mês: $e');
    }
  }

  Future<void> setMonthPurpose(String monthTitle, String purpose) async {
    _currentMonthPurpose = purpose;
    await _dbHelper.updateMonthMetadata(monthTitle, purpose: purpose);
    _safeNotify();
  }

  // ==========================================
  // --- Módulo: Metas & Travas por Categoria ---
  // ==========================================

  Future<void> setCategoryCap(String monthTitle, String category, double maxAmount) async {
    _categoryCaps[category] = maxAmount;
    final jsonStr = jsonEncode(_categoryCaps);
    await _dbHelper.updateMonthMetadata(monthTitle, categoryCaps: jsonStr);
    _safeNotify();
  }

  Future<void> removeCategoryCap(String monthTitle, String category) async {
    _categoryCaps.remove(category);
    final jsonStr = jsonEncode(_categoryCaps);
    await _dbHelper.updateMonthMetadata(monthTitle, categoryCaps: jsonStr);
    _safeNotify();
  }

  /// Retorna as categorias da lista ativa que excederam o teto estipulado
  List<Map<String, dynamic>> getExceededCategoryCaps() {
    if (_categoryCaps.isEmpty || _items.isEmpty) return [];

    final Map<String, double> spentByCategory = {};
    for (var it in _items) {
      final cat = it.category.trim();
      spentByCategory[cat] = (spentByCategory[cat] ?? 0.0) + it.totalPrice;
    }

    final List<Map<String, dynamic>> exceeded = [];
    for (var entry in _categoryCaps.entries) {
      final cat = entry.key;
      final cap = entry.value;
      final spent = spentByCategory[cat] ?? 0.0;
      if (spent > cap) {
        exceeded.add({
          'category': cat,
          'cap': cap,
          'spent': spent,
          'diff': spent - cap,
        });
      }
    }
    return exceeded;
  }

  // ==========================================
  // --- Módulo: Espaço Pessoal vs Família ---
  // ==========================================

  Future<void> setWorkspace(String workspace) async {
    _currentWorkspace = workspace;
    final filtered = await _dbHelper.getMonthsByWorkspace(workspace);
    _months = List.from(filtered);
    if (_months.isNotEmpty) {
      final target = findVigentMonth(_months) ?? _months.last;
      await _switchMonth(target);
    } else {
      _items = [];
      _safeNotify();
    }
  }

  Future<void> setMonthWorkspace(String monthTitle, String workspace) async {
    await _dbHelper.updateMonthMetadata(monthTitle, workspace: workspace);
    await setWorkspace(workspace);
  }

  @override
  void dispose() {
    _savePriceHistoryTimer?.cancel();
    super.dispose();
  }
}
