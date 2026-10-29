import 'package:flutter/material.dart';
import '../services/app_update_service.dart';

/// Modal compacto e amigável de instalação para o usuário final
class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;
  final String? readyApkPath;

  const AppUpdateDialog({super.key, required this.updateInfo, this.readyApkPath});

  static Future<void> show(BuildContext context, AppUpdateInfo info, {String? readyApkPath}) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: !info.forceUpdate,
      barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) => AppUpdateDialog(
        updateInfo: info,
        readyApkPath: readyApkPath,
      ),
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

  /// Atalho para exibir o diálogo com o arquivo APK já baixado e pronto
  static Future<void> showReady(BuildContext context, AppUpdateInfo info, String filePath) {
    return show(context, info, readyApkPath: filePath);
  }

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _errorMessage;
  bool _needsInstallPermission = false;
  String? _downloadedFilePath;
  bool _isNotesExpanded = false;

  @override
  void initState() {
    super.initState();
    _downloadedFilePath = widget.readyApkPath;
    if (_downloadedFilePath == null) {
      AppUpdateService.instance.getDownloadedApk(widget.updateInfo).then((file) {
        if (file != null && mounted) {
          setState(() {
            _downloadedFilePath = file.path;
          });
        }
      });
    }
  }

  Future<void> _checkPermissionAndInstall(String filePath) async {
    final canInstall = await AppUpdateService.instance.canRequestPackageInstalls();
    if (!canInstall) {
      if (mounted) {
        setState(() {
          _needsInstallPermission = true;
        });
      }
      return;
    }
    await _triggerInstall(filePath);
  }

  Future<void> _startDownloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0.0;
    });

    try {
      final file = await AppUpdateService.instance.downloadApk(
        apkUrl: widget.updateInfo.apkUrl,
        buildNumber: widget.updateInfo.buildNumber,
        version: widget.updateInfo.version,
        onProgress: (progress, received, total) {
          if (mounted) {
            setState(() {
              _progress = progress;
              _receivedBytes = received;
              _totalBytes = total;
            });
          }
        },
      );

      _downloadedFilePath = file.path;

      final canInstall = await AppUpdateService.instance.canRequestPackageInstalls();
      if (!canInstall) {
        if (mounted) {
          setState(() {
            _needsInstallPermission = true;
            _isDownloading = false;
          });
        }
        return;
      }

      await _triggerInstall(file.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  Future<void> _triggerInstall(String filePath) async {
    final success = await AppUpdateService.instance.installApk(filePath);
    if (success && mounted) {
      Navigator.pop(context);
    } else if (!success && mounted) {
      await AppUpdateService.instance.cleanOldDownloadedApks();
      setState(() {
        _isDownloading = false;
        _downloadedFilePath = null;
        _errorMessage = 'Não foi possível abrir o instalador do Android. O arquivo foi limpo do cache; tente baixar novamente.';
      });
    }
  }

  String _formatMb(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final info = widget.updateInfo;
    final isReady = _downloadedFilePath != null && !_isDownloading;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cabeçalho compacto
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (isReady ? const Color(0xFF10B981) : colorScheme.primary).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isReady ? Icons.check_circle_outline_rounded : Icons.system_update_rounded,
                        color: isReady ? const Color(0xFF10B981) : colorScheme.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isReady ? 'Atualização Pronta!' : 'Nova Versão',
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'CARRIN v${info.version}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: isReady ? const Color(0xFF10B981) : colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Mensagem concisa
                Text(
                  isReady
                      ? 'A nova versão foi baixada em segundo plano e já está pronta para instalar.'
                      : (_isDownloading
                          ? 'Baixando atualização em segundo plano...'
                          : 'Uma versão mais recente do aplicativo está disponível.'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),

                // Link Expansível: Notas da versão (recolhido por padrão)
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _isNotesExpanded = !_isNotesExpanded;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _isNotesExpanded ? 'Ocultar notas da versão' : 'Notas da versão',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            _isNotesExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Conteúdo das Notas quando expandido
                if (_isNotesExpanded) ...[
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (info.releaseNotes.isEmpty)
                            const Text('• Melhorias de desempenho e correções gerais.', style: TextStyle(fontSize: 12))
                          else
                            ...info.releaseNotes.map(
                              (note) => Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('• ', style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold, fontSize: 12)),
                                    Expanded(
                                      child: Text(
                                        note,
                                        style: const TextStyle(fontSize: 12, height: 1.3),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Barra de progresso caso esteja baixando
                if (_isDownloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: _totalBytes > 0 ? _progress : null,
                    borderRadius: BorderRadius.circular(8),
                    minHeight: 6,
                    backgroundColor: theme.dividerColor.withValues(alpha: 0.1),
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _totalBytes > 0 ? '${(_progress * 100).toInt()}%' : 'Baixando...',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: colorScheme.primary),
                      ),
                      if (_totalBytes > 0)
                        Text(
                          '${_formatMb(_receivedBytes)} / ${_formatMb(_totalBytes)}',
                          style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                        ),
                    ],
                  ),
                ],

                // Aviso de Permissão Android
                if (_needsInstallPermission) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'O Android precisa da sua autorização para instalar atualizações por este aplicativo.',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: () async {
                            await AppUpdateService.instance.openInstallPermissionSettings();
                            if (_downloadedFilePath != null) {
                              await _triggerInstall(_downloadedFilePath!);
                            }
                          },
                          icon: const Icon(Icons.security, size: 15),
                          label: const Text('Autorizar no Android', style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber.shade800,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Mensagem de Erro
                if (_errorMessage != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Botões de Ação
                if (!_isDownloading)
                  Row(
                    children: [
                      if (!info.forceUpdate)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              AppUpdateService.instance.dismissBuild(info.buildNumber);
                              Navigator.pop(context);
                            },
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: const Text('Depois'),
                          ),
                        ),
                      if (!info.forceUpdate) const SizedBox(width: 10),
                      Expanded(
                        flex: info.forceUpdate ? 1 : 2,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isReady) {
                              _checkPermissionAndInstall(_downloadedFilePath!);
                            } else {
                              _startDownloadAndInstall();
                            }
                          },
                          icon: Icon(isReady ? Icons.install_mobile_rounded : Icons.download_rounded, size: 18),
                          label: Text(
                            isReady ? 'Instalar Agora' : 'Instalar Atualização',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isReady ? const Color(0xFF10B981) : colorScheme.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
