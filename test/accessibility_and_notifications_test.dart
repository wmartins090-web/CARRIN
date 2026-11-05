import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lista_compras/theme/app_themes.dart';
import 'package:lista_compras/services/notification_service.dart';
import 'package:lista_compras/services/app_update_service.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('Accessibility & ColorBlindMode Tests', () {
    test('all ColorBlindMode values have non-empty labels, descriptions and preview colors', () {
      for (final mode in ColorBlindMode.values) {
        expect(mode.label.isNotEmpty, isTrue);
        expect(mode.description.isNotEmpty, isTrue);
        expect(mode.previewColors.length, equals(3));
      }
    });

    test('deuteranopia and protanopia provide high contrast royal blue and vermillion', () {
      final tp = ThemeProvider();
      
      // Default (none)
      expect(tp.successColor, equals(const Color(0xFF2D6A4F)));
      expect(tp.dangerColor, equals(const Color(0xFFE63946)));

      // Deuteranopia
      tp.setColorBlindMode(ColorBlindMode.deuteranopia);
      expect(tp.successColor, equals(const Color(0xFF0072B2)));
      expect(tp.dangerColor, equals(const Color(0xFFD55E00)));
      expect(tp.colorBlindMatrix, isNotNull);
      expect(tp.colorBlindMatrix!.length, equals(20));

      // Protanopia
      tp.setColorBlindMode(ColorBlindMode.protanopia);
      expect(tp.successColor, equals(const Color(0xFF0072B2)));
      expect(tp.dangerColor, equals(const Color(0xFFE69F00)));
      expect(tp.colorBlindMatrix!.length, equals(20));

      // Tritanopia
      tp.setColorBlindMode(ColorBlindMode.tritanopia);
      expect(tp.successColor, equals(const Color(0xFF009E73)));
      expect(tp.dangerColor, equals(const Color(0xFFCC79A7)));
      expect(tp.colorBlindMatrix!.length, equals(20));

      // High Contrast
      tp.setColorBlindMode(ColorBlindMode.highContrast);
      expect(tp.successColor, equals(const Color(0xFF00E676)));
      expect(tp.dangerColor, equals(const Color(0xFFFF1744)));
      expect(tp.colorBlindMatrix!.length, equals(20));
    });

    test('AppThemes.getTheme sets primary and error colors corresponding to colorBlindMode', () {
      final lightDeut = AppThemes.getTheme(AppColors.iconGreen, false, colorBlindMode: ColorBlindMode.deuteranopia);
      expect(lightDeut.colorScheme.primary, equals(const Color(0xFF0072B2)));
      expect(lightDeut.colorScheme.error, equals(const Color(0xFFD55E00)));

      final darkDeut = AppThemes.getTheme(AppColors.iconGreen, true, colorBlindMode: ColorBlindMode.deuteranopia);
      expect(darkDeut.colorScheme.primary, equals(const Color(0xFF0072B2)));
      expect(darkDeut.colorScheme.error, equals(const Color(0xFFD55E00)));

      final lightTrit = AppThemes.getTheme(AppColors.iconGreen, false, colorBlindMode: ColorBlindMode.tritanopia);
      expect(lightTrit.colorScheme.primary, equals(const Color(0xFF009E73)));
      expect(lightTrit.colorScheme.error, equals(const Color(0xFFCC79A7)));
    });
  });

  group('NotificationService Contract Tests', () {
    test('constants and resource identifiers are defined correctly', () {
      expect(NotificationService.channelId, equals('shopping_list_progress_v5'));
      expect(NotificationService.budgetChannelId, equals('budget_alerts_v2'));
      expect(NotificationService.cartNotificationIcon, equals('ic_notification_cart'));
      expect(NotificationService.appLogoIcon, equals('ic_carrin_logo'));
      expect(NotificationService.updateChannelId, equals('app_updates_v1'));
      expect(NotificationService.progressNotificationId, equals(0));
      expect(NotificationService.budgetNotificationId, equals(1));
      expect(NotificationService.updateAvailableNotificationId, equals(2));
      expect(NotificationService.updateReadyNotificationId, equals(3));
    });

    test('shopping progress manual dismissal respects session state until restarted', () {
      final service = NotificationService();
      expect(service.isProgressDismissedForSession, isFalse);

      service.resetProgressSessionDismissal();
      expect(service.isProgressDismissedForSession, isFalse);
    });

    test('update dismissal persists build number and version', () async {
      final updateService = AppUpdateService.instance;
      
      expect(await updateService.isBuildDismissed(622, version: '1.3.622'), isFalse);

      await updateService.dismissBuild(622, version: '1.3.622');

      expect(await updateService.isBuildDismissed(622, version: '1.3.622'), isTrue);
      // Older or equal build numbers should also be considered dismissed
      expect(await updateService.isBuildDismissed(621, version: '1.3.621'), isTrue);
      // Newer build numbers should not be dismissed
      expect(await updateService.isBuildDismissed(623, version: '1.3.623'), isFalse);
    });
  });
}
