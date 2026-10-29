import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_themes.dart';
import '../providers/item_provider.dart';
import '../services/backup_service.dart';
import 'accounts_screen.dart';
import 'buyer_profile_screen.dart';
import 'terms_screen.dart';
import '../widgets/supermarket_avatar.dart';
import '../widgets/theme_color_picker_sheet.dart';
import '../widgets/interactive_tab_tutorial.dart';
import '../services/utils.dart';
import '../services/app_update_service.dart';
import '../widgets/app_update_dialog.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final itemProvider = Provider.of<ItemProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded),
            tooltip: 'Tutorial Interativo desta Aba',
            onPressed: () => InteractiveTabTutorial.show(
              context,
              TutorialSection.settings,
              userEmail: itemProvider.activeUserEmail,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),        children: [
          const Text('CONTAS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: itemProvider.activeUserDisplayName,
            subtitle: itemProvider.isActiveUserOffline ? '' : (itemProvider.activeUserEmail ?? ''),
            leadingWidget: SupermarketAvatarWidget(
              photoUrl: itemProvider.activeUserPhotoUrl,
              displayName: itemProvider.activeUserDisplayName,
              radius: 18,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AccountsScreen()),
              );
            },
          ),
          _buildSettingItem(
            context,
            title: 'Perfil de Comprador',
            subtitle: 'Hábitos de compra, arquétipo e categorias',
            icon: Icons.psychology_alt_rounded,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BuyerProfileScreen()),
              );
            },
          ),
          
          const SizedBox(height: 24),
          const Text('DADOS E SINCRONIZAÇÃO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Exportar Backup',
            subtitle: 'Salvar listas em um arquivo',
            icon: Icons.unarchive_outlined,
            onTap: () => _handleExport(context),
          ),
          _buildSettingItem(
            context,
            title: 'Importar Backup',
            subtitle: 'Restaurar listas de um arquivo',
            icon: Icons.archive_outlined,
            onTap: () => _handleImport(context, itemProvider),
          ),
          _buildSettingItem(
            context,
            title: 'Limpar Cache local',
            subtitle: 'Força a atualização total da nuvem',
            icon: Icons.delete_sweep_outlined,
            onTap: () => _showClearCacheDialog(context, itemProvider),
          ),
          const SizedBox(height: 24),
          const Text('PLANEJAMENTO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Orçamento Padrão',
            subtitle: itemProvider.defaultBudget > 0 
                ? 'R\$ ${itemProvider.defaultBudget.toStringAsFixed(2).replaceAll('.', ',')}'
                : 'Não configurado',
            icon: Icons.account_balance_wallet_outlined,
            onTap: () => _showDefaultBudgetDialog(context, itemProvider),
          ),
          _buildSettingItem(
            context,
            title: 'Itens Essenciais',
            subtitle: 'Gerenciar produtos recorrentes',
            icon: Icons.auto_awesome_motion_outlined,
            onTap: () => _showEssentialsDialog(context, itemProvider),
          ),
          
          const SizedBox(height: 24),
          const Text('APARÊNCIA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Tema do Aplicativo',
            subtitle: '${themeProvider.isDarkMode ? 'Modo Escuro' : 'Modo Claro'} • ${AppColors.getColorName(themeProvider.seedColor)}',
            icon: Icons.palette_outlined,
            onTap: () => ThemeColorPickerSheet.show(context, themeProvider),
          ),
          
          _buildSettingItem(
            context,
            title: 'Animações',
            subtitle: 'Personalizar efeitos visuais',
            icon: Icons.auto_fix_high_outlined,
            onTap: () => _showAnimationSettingsDialog(context, itemProvider),
          ),
          
          _buildSettingItem(
            context,
            title: 'Ícone do Aplicativo',
            subtitle: (themeProvider.appIcon.contains('app_icon') || themeProvider.appIcon.contains('1.png')) ? 'Padrão' : 'Moderno',
            icon: Icons.image_outlined,
            onTap: () => _showIconDialog(context, themeProvider),
          ),

          const SizedBox(height: 24),
          const Text('ACESSIBILIDADE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Modo Daltônico',
            subtitle: themeProvider.colorBlindModeLabel,
            icon: Icons.visibility_outlined,
            onTap: () => _showColorBlindModeDialog(context, themeProvider),
          ),
          _buildSettingItem(
            context,
            title: 'Tamanho das Letras',
            subtitle: themeProvider.fontScaleLabel,
            icon: Icons.format_size_rounded,
            onTap: () => _showFontSizeDialog(context, themeProvider),
          ),

          const SizedBox(height: 24),
          const Text('AJUDA E SUPORTE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Resetar Tutoriais das Abas',
            subtitle: 'Exibir novamente os cards interativos ao entrar em cada aba',
            icon: Icons.replay_circle_filled_outlined,
            onTap: () async {
              await InteractiveTabTutorial.resetAllTabTutorials(userEmail: itemProvider.activeUserEmail);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Tutoriais das abas reativados! Eles aparecerão na sua próxima visita a cada seção.'),
                    duration: Duration(seconds: 3),
                  ),
                );
              }
            },
          ),
          _buildSettingItem(
            context,
            title: 'Termos e Privacidade',
            subtitle: 'Conformidade com a LGPD',
            icon: Icons.privacy_tip_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const TermsScreen()),
              );
            },
          ),

          const SizedBox(height: 24),
          const Text('ATUALIZAÇÕES & SOBRE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.1)),
          const SizedBox(height: 12),
          _buildSettingItem(
            context,
            title: 'Verificar Atualizações',
            subtitle: 'v${AppUpdateService.currentAppVersion} (Build ${AppUpdateService.currentBuildNumber}) • Notificações automáticas ativas',
            icon: Icons.system_update_rounded,
            onTap: () => _handleCheckUpdate(context),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCheckUpdate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Verificando se há novas atualizações...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    final info = await AppUpdateService.instance.checkForUpdate(ignoreDismissed: true);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();

    if (info != null) {
      final cached = await AppUpdateService.instance.getDownloadedApk(info);
      if (cached != null) {
        if (!context.mounted) return;
        AppUpdateDialog.showReady(context, info, cached.path);
      } else if (AppUpdateService.instance.isDownloadingInBackground) {
        final prog = (AppUpdateService.instance.backgroundProgress * 100).toInt();
        messenger.showSnackBar(
          SnackBar(
            content: Text('A nova versão (v${info.version}) já está sendo baixada em segundo plano ($prog%). Você será avisado assim que concluir!'),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.blue.shade700,
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Nova versão v${info.version} encontrada! Baixando silenciosamente em segundo plano...'),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.blue.shade700,
          ),
        );
        AppUpdateService.instance.downloadInBackground(
          info,
          onReady: (readyInfo, apkPath) {
            if (context.mounted) {
              AppUpdateDialog.showReady(context, readyInfo, apkPath);
            }
          },
        );
      }
    } else if (AppUpdateService.instance.lastFetchError != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(AppUpdateService.instance.lastFetchError!)),
            ],
          ),
          duration: const Duration(seconds: 5),
          backgroundColor: Colors.orange.shade800,
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('🎉 Você já está usando a versão mais recente! (v${AppUpdateService.currentAppVersion})'),
          duration: const Duration(seconds: 3),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  void _showAnimatedDialog(BuildContext context, Widget dialog) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) => dialog,
      transitionBuilder: (context, anim1, anim2, child) {
        final curve = Curves.easeOutBack.transform(anim1.value);
        return Transform.scale(
          scale: curve,
          child: Opacity(
            opacity: anim1.value,
            child: child,
          ),
        );
      },
    );
  }

  void _showClearCacheDialog(BuildContext context, ItemProvider provider) {
    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Limpar Cache?', style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Isso apagará os dados locais e sincronizará tudo novamente com a nuvem.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await provider.clearAllCache();
              if (context.mounted) {
                _showRestartAppDialog(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Limpar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }



  void _showRestartAppDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Dados Restaurados!', style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Para aplicar o backup importado, o aplicativo precisa ser reiniciado.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
            },
            child: const Text('Reiniciar Agora', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleExport(BuildContext context) async {
    try {
      await BackupService.exportBackup();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao exportar: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _handleImport(BuildContext context, ItemProvider provider) async {
    try {
      final success = await BackupService.importBackup();
      if (success && context.mounted) {
        // Force the provider to reload the data it just got from the backup
        await provider.forceReload();
        if (context.mounted) {
          _showRestartAppDialog(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao importar: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Widget _buildSettingItem(BuildContext context, {
    required String title,
    required String subtitle,
    IconData? icon,
    Widget? leadingWidget,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return ListTile(
      leading: leadingWidget ?? Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: isDestructive ? Colors.redAccent.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: Icon(icon, size: 20, color: isDestructive ? Colors.redAccent : null),
      ),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: isDestructive ? Colors.redAccent : null)),
      subtitle: subtitle.isNotEmpty ? Text(subtitle, style: const TextStyle(fontSize: 13)) : null,
      trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
      onTap: onTap,
    );
  }

  void _showIconDialog(BuildContext context, ThemeProvider provider) {
    _showAnimatedDialog(
      context,
      SimpleDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Escolher Ícone', style: TextStyle(fontWeight: FontWeight.bold)),
        children: [
          _buildIconOption(
            context,
            title: 'Padrão',
            iconPath: 'assets/images/app_icon.png',
            isSelected: provider.appIcon.contains('app_icon') || provider.appIcon.contains('1.png'),
            onTap: () {
              provider.setAppIcon('assets/images/app_icon.png');
              Navigator.pop(context);
            },
          ),
          _buildIconOption(
            context,
            title: 'Moderno',
            iconPath: 'assets/images/app_logo_transparent.png',
            isSelected: provider.appIcon.contains('logo_transparent') || provider.appIcon.contains('removebg'),
            onTap: () {
              provider.setAppIcon('assets/images/app_logo_transparent.png');
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIconOption(BuildContext context, {
    required String title,
    required String iconPath,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return SimpleDialogOption(
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: isSelected ? BoxDecoration(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ) : null,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: Image.asset(iconPath, fit: BoxFit.contain),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(title, style: TextStyle(fontSize: 16, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))),
            if (isSelected) const Icon(Icons.check_circle, color: Colors.green, size: 20),
          ],
        ),
      ),
    );
  }

  void _showEssentialsDialog(BuildContext context, ItemProvider provider) {
    final controller = TextEditingController();
    
    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Itens Essenciais', style: TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Estes itens podem ser importados automaticamente para novas listas.', style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'Ex: Arroz, Café...',
                          border: UnderlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add_circle, color: Theme.of(context).primaryColor),
                      onPressed: () {
                        if (controller.text.trim().isNotEmpty) {
                          provider.toggleEssentialItem(controller.text.trim());
                          controller.clear();
                          setModalState(() {});
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (provider.essentialItems.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('Nenhum item adicionado.', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),
                  )
                else
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: provider.essentialItems.length,
                        itemBuilder: (context, index) {
                          final item = provider.essentialItems[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(item),
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                              onPressed: () {
                                provider.toggleEssentialItem(item);
                                setModalState(() {});
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Restaurar Padrões?'),
                    content: const Text('Isso substituirá sua lista atual de itens essenciais pelos padrões recomendados.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancelar'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                        child: const Text('Restaurar'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await provider.resetEssentialItemsToDefault();
                  setModalState(() {});
                }
              },
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('Restaurar Padrões'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }



  void _showAnimationSettingsDialog(BuildContext context, ItemProvider provider) {
    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Animações', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAnimationSwitch(
                context, 
                title: 'Entrada de Listas',
                subtitle: 'Efeito nos itens e grades',
                value: provider.animationSettings['list_animations'] ?? true,
                icon: Icons.format_list_bulleted_rounded,
                onChanged: (val) {
                  provider.updateAnimationSetting('list_animations', val);
                  setModalState(() {});
                },
              ),
              _buildAnimationSwitch(
                context, 
                title: 'Velocímetros',
                subtitle: 'Indicadores circulares',
                value: provider.animationSettings['gauge_animations'] ?? true,
                icon: Icons.speed_rounded,
                onChanged: (val) {
                  provider.updateAnimationSetting('gauge_animations', val);
                  setModalState(() {});
                },
              ),
              _buildAnimationSwitch(
                context, 
                title: 'Gráficos',
                subtitle: 'Linhas de histórico',
                value: provider.animationSettings['chart_animations'] ?? true,
                icon: Icons.show_chart_rounded,
                onChanged: (val) {
                  provider.updateAnimationSetting('chart_animations', val);
                  setModalState(() {});
                },
              ),
              _buildAnimationSwitch(
                context, 
                title: 'Notificações de Progresso',
                subtitle: 'Barra de status com total gasto',
                value: provider.animationSettings['enable_notifications'] ?? true,
                icon: Icons.notifications_active_outlined,
                onChanged: (val) {
                  provider.updateAnimationSetting('enable_notifications', val);
                  setModalState(() {});
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimationSwitch(BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required IconData icon,
    required Function(bool) onChanged,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      activeThumbColor: Theme.of(context).primaryColor,
      secondary: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: Icon(icon, size: 20, color: Theme.of(context).iconTheme.color),
      ),
    );
  }

  void _showDefaultBudgetDialog(BuildContext context, ItemProvider provider) {
    final controller = TextEditingController(
      text: provider.defaultBudget > 0 
          ? Utils.formatCurrencyInput(provider.defaultBudget)
          : '',
    );
    if (controller.text.isNotEmpty) controller.selection = TextSelection.collapsed(offset: controller.text.length);
    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Orçamento Padrão', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Defina o orçamento padrão para novos meses/carrinhos:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [CurrencyInputFormatter()],
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Valor padrão',
                hintText: '0,00',
                prefixText: 'R\$ ',
                border: UnderlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              final value = Utils.parseCurrency(text);
              provider.updateDefaultBudget(value);
              Navigator.pop(context);
            },
            child: const Text('Salvar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showColorBlindModeDialog(BuildContext context, ThemeProvider themeProvider) {
    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            title: Row(
              children: [
                Icon(Icons.visibility_outlined, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(child: Text('Modo Daltônico', style: TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Selecione uma paleta adaptada para máxima clareza e distinção entre itens comprados, alertas e gráficos:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  ...ColorBlindMode.values.map((mode) {
                    final isSelected = themeProvider.colorBlindMode == mode;
                    return InkWell(
                      onTap: () {
                        themeProvider.setColorBlindMode(mode);
                        setDialogState(() {});
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected
                                ? Theme.of(context).primaryColor
                                : Colors.grey.withValues(alpha: 0.2),
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              margin: const EdgeInsets.only(right: 12),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelected ? Theme.of(context).primaryColor : Colors.transparent,
                                border: Border.all(
                                  color: isSelected ? Theme.of(context).primaryColor : Colors.grey.shade400,
                                  width: 2,
                                ),
                              ),
                              child: isSelected
                                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                                  : null,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          mode.label,
                                          style: TextStyle(
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: mode.previewColors.map((color) => Container(
                                          width: 14,
                                          height: 14,
                                          margin: const EdgeInsets.only(left: 4),
                                          decoration: BoxDecoration(
                                            color: color,
                                            shape: BoxShape.circle,
                                            border: Border.all(color: Colors.white, width: 1.5),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.15),
                                                blurRadius: 3,
                                              ),
                                            ],
                                          ),
                                        )).toList(),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    mode.description,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Concluído', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showFontSizeDialog(BuildContext context, ThemeProvider themeProvider) {
    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (ctx, setDialogState) {
          final scale = themeProvider.fontScale;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            title: Row(
              children: [
                Icon(Icons.format_size_rounded, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(child: Text('Tamanho das Letras', style: TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Ajuste o tamanho do texto para facilitar a leitura em todas as telas:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  
                  // Caixa de Pré-Visualização em Tempo Real
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).primaryColor.withValues(alpha: 0.3)),
                    ),
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.shopping_bag_outlined, size: 20),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Arroz Integral 5kg',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '2 unidades • Total: R\$ 29,90',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Escala atual
                  Center(
                    child: Text(
                      themeProvider.fontScaleLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Slider
                  Slider(
                    value: scale.clamp(0.85, 1.45),
                    min: 0.85,
                    max: 1.45,
                    divisions: 4,
                    label: themeProvider.fontScaleLabel,
                    onChanged: (newScale) {
                      themeProvider.setFontScale(newScale);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 8),

                  // Chips com Atalhos Rápidos
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildFontScaleChip(context, themeProvider, 0.85, 'Pequeno', setDialogState),
                      _buildFontScaleChip(context, themeProvider, 1.0, 'Padrão', setDialogState),
                      _buildFontScaleChip(context, themeProvider, 1.15, 'Médio', setDialogState),
                      _buildFontScaleChip(context, themeProvider, 1.30, 'Grande', setDialogState),
                      _buildFontScaleChip(context, themeProvider, 1.45, 'Muito Grande', setDialogState),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  themeProvider.setFontScale(1.0);
                  setDialogState(() {});
                },
                child: const Text('Restaurar Padrão', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Concluído', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFontScaleChip(
    BuildContext context, 
    ThemeProvider provider, 
    double targetScale, 
    String label, 
    void Function(void Function()) setDialogState
  ) {
    final isSelected = (provider.fontScale - targetScale).abs() < 0.05;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      selected: isSelected,
      onSelected: (_) {
        provider.setFontScale(targetScale);
        setDialogState(() {});
      },
    );
  }
}
