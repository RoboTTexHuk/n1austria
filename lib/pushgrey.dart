import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as NcupMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as NcupTimezoneData;
import 'package:timezone/timezone.dart' as NcupTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// NCUP инфраструктура (бывшая Dress Retro инфраструктура)
// ============================================================================

class NcupLogger {
  const NcupLogger();

  void NcupLogInfo(Object NcupMessage) =>
      debugPrint('[DressRetroLogger] $NcupMessage');

  void NcupLogWarn(Object NcupMessage) =>
      debugPrint('[DressRetroLogger/WARN] $NcupMessage');

  void NcupLogError(Object NcupMessage) =>
      debugPrint('[DressRetroLogger/ERR] $NcupMessage');
}

class NcupVault {
  static final NcupVault SharedInstance = NcupVault._InternalConstructor();
  NcupVault._InternalConstructor();
  factory NcupVault() => SharedInstance;

  final NcupLogger NcupLoggerInstance = const NcupLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String MetrLoadedOnceKey = 'wheel_loaded_once';
const String MetrStatEndpoint = 'https://getgame.portalroullete.bar/stat';
const String MetrCachedFcmKey = 'wheel_cached_fcm';

// НОВОЕ: ключи для сохранения SafeArea и цвета в SharedPreferences
const String NcupSafeAreaEnabledKey = 'safearea_enabled';
const String NcupSafeAreaColorKey = 'safearea_color';
const String NcupCachedUserAgentKey = 'ncup_cached_user_agent';

// ---------------- Bank constants (из первого main.dart) ----------------

const Set<String> kBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> kBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Утилиты: NcupKit (бывший DressRetroKit)
// ============================================================================

class NcupKit {
  static bool NcupLooksLikeBareMail(Uri NcupUri) {
    final String NcupScheme = NcupUri.scheme;
    if (NcupScheme.isNotEmpty) return false;
    final String NcupRaw = NcupUri.toString();
    return NcupRaw.contains('@') && !NcupRaw.contains(' ');
  }

  static Uri NcupToMailto(Uri NcupUri) {
    final String NcupFull = NcupUri.toString();
    final List<String> NcupBits = NcupFull.split('?');
    final String NcupWho = NcupBits.first;
    final Map<String, String> NcupQuery =
    NcupBits.length > 1 ? Uri.splitQueryString(NcupBits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: NcupWho,
      queryParameters: NcupQuery.isEmpty ? null : NcupQuery,
    );
  }

  static Uri NcupGmailize(Uri NcupMailUri) {
    final Map<String, String> NcupQp = NcupMailUri.queryParameters;
    final Map<String, String> NcupParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (NcupMailUri.path.isNotEmpty) 'to': NcupMailUri.path,
      if ((NcupQp['subject'] ?? '').isNotEmpty) 'su': NcupQp['subject']!,
      if ((NcupQp['body'] ?? '').isNotEmpty) 'body': NcupQp['body']!,
      if ((NcupQp['cc'] ?? '').isNotEmpty) 'cc': NcupQp['cc']!,
      if ((NcupQp['bcc'] ?? '').isNotEmpty) 'bcc': NcupQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', NcupParams);
  }

  static String NcupDigitsOnly(String NcupSource) =>
      NcupSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: NcupLinker (бывший DressRetroLinker)
// ============================================================================

class NcupLinker {
  static Future<bool> NcupOpen(Uri NcupUri) async {
    try {
      if (await launchUrl(
        NcupUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        NcupUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (NcupError) {
      debugPrint('DressRetroLinker error: $NcupError; url=$NcupUri');
      try {
        return await launchUrl(
          NcupUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// Bank helpers (из первого main.dart)
// ============================================================================

bool NcupIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kBankSchemes.contains(scheme);
}

bool NcupIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> NcupOpenBank(Uri uri) async {
  try {
    if (NcupIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        NcupIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    debugPrint('NcupOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> NcupFcmBackgroundHandler(RemoteMessage NcupMessage) async {
  debugPrint("Spin ID: ${NcupMessage.messageId}");
  debugPrint("Spin Data: ${NcupMessage.data}");
}

// ============================================================================
// NcupDeviceProfile (бывший DressRetroDeviceProfile)
// ============================================================================

class NcupDeviceProfile {
  String? NcupDeviceId;
  String? NcupSessionId = 'wheel-one-off';
  String? NcupPlatformKind;
  String? NcupOsBuild;
  String? NcupAppVersion;
  String? NcupLocaleCode;
  String? NcupTimezoneName;
  bool NcupPushEnabled = true;

  // Новый UA из WebView
  String? NcupBaseUserAgent;

  // Для SafeArea
  bool NcupSafeAreaEnabled = false;
  String? NcupSafeAreaColor;

  Future<void> NcupInitialize() async {
    try {
      NcupTimezoneData.initializeTimeZones();
    } catch (_) {}

    final DeviceInfoPlugin NcupInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo NcupAndroidInfo =
      await NcupInfoPlugin.androidInfo;
      NcupDeviceId = NcupAndroidInfo.id;
      NcupPlatformKind = 'android';
      NcupOsBuild = NcupAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo NcupIosInfo = await NcupInfoPlugin.iosInfo;
      NcupDeviceId = NcupIosInfo.identifierForVendor;
      NcupPlatformKind = 'ios';
      NcupOsBuild = NcupIosInfo.systemVersion;
    }

    final PackageInfo NcupPackageInfo = await PackageInfo.fromPlatform();
    NcupAppVersion = NcupPackageInfo.version;
    NcupLocaleCode = Platform.localeName.split('_').first;
    NcupTimezoneName = NcupTimezone.local.name;
    NcupSessionId = 'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> NcupAsMap({String? NcupFcmToken}) => <String, dynamic>{
    'fcm_token': NcupFcmToken ?? 'missing_token',
    'device_id': NcupDeviceId ?? 'missing_id',
    'app_name': 'joiler',
    'instance_id': NcupSessionId ?? 'missing_session',
    'platform': NcupPlatformKind ?? 'missing_system',
    'os_version': NcupOsBuild ?? 'missing_build',
    'app_version': NcupAppVersion ?? 'missing_app',
    'language': NcupLocaleCode ?? 'en',
    'timezone': NcupTimezoneName ?? 'UTC',
    'push_enabled': NcupPushEnabled,
    'fthcashier': 'true',
    'safearea': NcupSafeAreaEnabled,
    'safearea_color': NcupSafeAreaColor ?? '',
    'base_ua': NcupBaseUserAgent ?? '',
  };
}

// ============================================================================
// AppsFlyer шпион: NcupSpy (бывший DressRetroSpy)
// ============================================================================

class NcupSpy {
  AppsFlyerOptions? NcupOptions;
  AppsflyerSdk? NcupSdk;

  String NcupAppsFlyerUid = '';
  String NcupAppsFlyerData = '';

  void NcupStart({VoidCallback? NcupOnUpdate}) {
    final AppsFlyerOptions NcupOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    NcupOptions = NcupOpts;
    NcupSdk = AppsflyerSdk(NcupOpts);

    NcupSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    NcupSdk?.startSDK(
      onSuccess: () =>
          NcupVault().NcupLoggerInstance.NcupLogInfo('WheelSpy started'),
      onError: (NcupCode, NcupMsg) => NcupVault()
          .NcupLoggerInstance
          .NcupLogError('WheelSpy error $NcupCode: $NcupMsg'),
    );

    NcupSdk?.onInstallConversionData((NcupValue) {
      NcupAppsFlyerData = NcupValue.toString();
      NcupOnUpdate?.call();
    });

    NcupSdk?.getAppsFlyerUID().then((NcupValue) {
      NcupAppsFlyerUid = NcupValue.toString();
      NcupOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: NcupFcmBridge (бывший DressRetroFcmBridge)
// ============================================================================

class NcupFcmBridge {
  final NcupLogger NcupLog = const NcupLogger();
  String? NcupToken;
  final List<void Function(String)> NcupWaiters = <void Function(String)>[];

  String? get NcupCurrentToken => NcupToken;

  NcupFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall NcupCall) async {
      if (NcupCall.method == 'setToken') {
        final String NcupTokenString = NcupCall.arguments as String;
        if (NcupTokenString.isNotEmpty) {
          NcupSetToken(NcupTokenString);
        }
      }
    });

    NcupRestoreToken();
  }

  Future<void> NcupRestoreToken() async {
    try {
      final SharedPreferences NcupPrefs = await SharedPreferences.getInstance();
      final String? NcupCached = NcupPrefs.getString(MetrCachedFcmKey);
      if (NcupCached != null && NcupCached.isNotEmpty) {
        NcupSetToken(NcupCached, NcupNotify: false);
      }
    } catch (_) {}
  }

  Future<void> NcupPersistToken(String NcupNewToken) async {
    try {
      final SharedPreferences NcupPrefs = await SharedPreferences.getInstance();
      await NcupPrefs.setString(MetrCachedFcmKey, NcupNewToken);
    } catch (_) {}
  }

  void NcupSetToken(
      String NcupNewToken, {
        bool NcupNotify = true,
      }) {
    NcupToken = NcupNewToken;
    NcupPersistToken(NcupNewToken);
    if (NcupNotify) {
      for (final void Function(String) NcupCallback
      in List<void Function(String)>.from(NcupWaiters)) {
        try {
          NcupCallback(NcupNewToken);
        } catch (NcupErr) {
          NcupLog.NcupLogWarn('fcm waiter error: $NcupErr');
        }
      }
      NcupWaiters.clear();
    }
  }

  Future<void> NcupWaitForToken(
      Function(String NcupTokenValue) NcupOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((NcupToken ?? '').isNotEmpty) {
        NcupOnToken(NcupToken!);
        return;
      }

      NcupWaiters.add(NcupOnToken);
    } catch (NcupErr) {
      NcupLog.NcupLogError('wheelWaitToken error: $NcupErr');
    }
  }
}

// ============================================================================
// NcupLoader (новый лоадер)
// ============================================================================

class NcupLoader extends StatefulWidget {
  const NcupLoader({Key? key}) : super(key: key);

  @override
  State<NcupLoader> createState() => _NcupLoaderState();
}

class _NcupLoaderState extends State<NcupLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController NcupController;

  static const Color NcupBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    NcupController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    NcupController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NcupBackgroundColor,
      child: AnimatedBuilder(
        animation: NcupController,
        builder: (BuildContext context, Widget? child) {
          final double NcupPhase = NcupController.value * 2 * NcupMath.pi;
          return CustomPaint(
            painter: NcupLoaderPainter(
              NcupPhase: NcupPhase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class NcupLoaderPainter extends CustomPainter {
  final double NcupPhase;

  NcupLoaderPainter({
    required this.NcupPhase,
  });

  @override
  void paint(Canvas NcupCanvas, Size NcupSize) {
    final double NcupWidth = NcupSize.width;
    final double NcupHeight = NcupSize.height;

    final Paint NcupBackgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    NcupCanvas.drawRect(Offset.zero & NcupSize, NcupBackgroundPaint);

    final double NcupPulse = (NcupMath.sin(NcupPhase) + 1) / 2;

    final Paint NcupCirclePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * NcupPulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(NcupWidth * 0.5, NcupHeight * 0.45),
          radius: NcupHeight * (0.4 + 0.15 * NcupPulse),
        ),
      );

    NcupCanvas.drawCircle(
      Offset(NcupWidth * 0.5, NcupHeight * 0.45),
      NcupHeight * (0.4 + 0.15 * NcupPulse),
      NcupCirclePaint,
    );

    final Paint NcupOuterPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent.withOpacity(0.10 + 0.10 * (1 - NcupPulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(NcupWidth * 0.5, NcupHeight * 0.45),
          radius: NcupHeight * (0.55 + 0.10 * (1 - NcupPulse)),
        ),
      );
    NcupCanvas.drawCircle(
      Offset(NcupWidth * 0.5, NcupHeight * 0.45),
      NcupHeight * (0.55 + 0.10 * (1 - NcupPulse)),
      NcupOuterPaint,
    );

    final double NcupBaseSize = NcupWidth * 0.35;
    final double NcupFontSize =
        NcupBaseSize + NcupPulse * (NcupBaseSize * 0.15);

    const String NcupLetter = 'N';
    const String NcupWord = 'CUP';

    final TextPainter NcupLetterPainter = TextPainter(
      text: TextSpan(
        text: NcupLetter,
        style: TextStyle(
          fontSize: NcupFontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * NcupPulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: NcupWidth);

    final double NcupLetterX = (NcupWidth - NcupLetterPainter.width) / 2;
    final double NcupLetterY = (NcupHeight - NcupLetterPainter.height) / 2;

    final Offset NcupLetterOffset = Offset(NcupLetterX, NcupLetterY);

    final Rect NcupLetterRect = Rect.fromCenter(
      center: Offset(NcupWidth / 2, NcupHeight / 2),
      width: NcupLetterPainter.width * 1.4,
      height: NcupLetterPainter.height * 1.6,
    );

    final Paint NcupGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * NcupPulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * NcupPulse);

    NcupCanvas.saveLayer(NcupLetterRect, NcupGlowPaint);
    NcupLetterPainter.paint(NcupCanvas, NcupLetterOffset);
    NcupCanvas.restore();

    NcupLetterPainter.paint(NcupCanvas, NcupLetterOffset);

    final double NcupCupFontSize = NcupWidth * 0.11;

    final TextPainter NcupCupPainterReal = TextPainter(
      text: TextSpan(
        text: NcupWord,
        style: TextStyle(
          fontSize: NcupCupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * NcupPulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: NcupWidth);

    final double NcupCupX = (NcupWidth - NcupCupPainterReal.width) / 2;
    final double NcupCupY =
        NcupLetterY + NcupLetterPainter.height + NcupHeight * 0.03;

    final Offset NcupCupOffset = Offset(NcupCupX, NcupCupY);
    NcupCupPainterReal.paint(NcupCanvas, NcupCupOffset);
  }

  @override
  bool shouldRepaint(covariant NcupLoaderPainter NcupOldDelegate) =>
      NcupOldDelegate.NcupPhase != NcupPhase;
}

// ============================================================================
// Статистика (NcupFinalUrl / NcupPostStat) — строки не меняем
// ============================================================================

Future<String> NcupFinalUrl(
    String NcupStartUrl, {
      int NcupMaxHops = 10,
    }) async {
  final HttpClient NcupClient = HttpClient();

  try {
    Uri NcupCurrentUri = Uri.parse(NcupStartUrl);

    for (int NcupI = 0; NcupI < NcupMaxHops; NcupI++) {
      final HttpClientRequest NcupRequest =
      await NcupClient.getUrl(NcupCurrentUri);
      NcupRequest.followRedirects = false;
      final HttpClientResponse NcupResponse = await NcupRequest.close();

      if (NcupResponse.isRedirect) {
        final String? NcupLoc =
        NcupResponse.headers.value(HttpHeaders.locationHeader);
        if (NcupLoc == null || NcupLoc.isEmpty) break;

        final Uri NcupNextUri = Uri.parse(NcupLoc);
        NcupCurrentUri = NcupNextUri.hasScheme
            ? NcupNextUri
            : NcupCurrentUri.resolveUri(NcupNextUri);
        continue;
      }

      return NcupCurrentUri.toString();
    }

    return NcupCurrentUri.toString();
  } catch (NcupError) {
    debugPrint('wheelFinalUrl error: $NcupError');
    return NcupStartUrl;
  } finally {
    NcupClient.close(force: true);
  }
}

Future<void> NcupPostStat({
  required String NcupEvent,
  required int NcupTimeStart,
  required String NcupUrl,
  required int NcupTimeFinish,
  required String NcupAppSid,
  int? NcupFirstPageTs,
}) async {
  try {
    final String NcupResolvedUrl = await NcupFinalUrl(NcupUrl);
    final Map<String, dynamic> NcupPayload = <String, dynamic>{
      'event': NcupEvent,
      'timestart': NcupTimeStart,
      'timefinsh': NcupTimeFinish,
      'url': NcupResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$NcupAppSid/$NcupTimeStart',
    };

    debugPrint('wheelStat $NcupPayload');

    final http.Response NcupResp = await http.post(
      Uri.parse('$MetrStatEndpoint/$NcupAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(NcupPayload),
    );

    debugPrint('wheelStat resp=${NcupResp.statusCode} body=${NcupResp.body}');
  } catch (NcupError) {
    debugPrint('wheelPostStat error: $NcupError');
  }
}

// ============================================================================
// WebView-экран: NcupTableView (бывший DressRetroTableView)
// SafeArea + SafeArea color + localStorage подхватываются из SharedPreferences
// ============================================================================

class NcupTableView extends StatefulWidget with WidgetsBindingObserver {
  String NcupStartingUrl;
  NcupTableView(this.NcupStartingUrl, {super.key});

  @override
  State<NcupTableView> createState() => _NcupTableViewState(NcupStartingUrl);
}

class _NcupTableViewState extends State<NcupTableView>
    with WidgetsBindingObserver {
  _NcupTableViewState(this.NcupCurrentUrl);

  final NcupVault NcupVaultInstance = NcupVault();

  late InAppWebViewController NcupWebViewController;
  String? NcupPushToken;
  final NcupDeviceProfile NcupDeviceProfileInstance = NcupDeviceProfile();
  final NcupSpy NcupSpyInstance = NcupSpy();

  bool NcupOverlayBusy = false;
  String NcupCurrentUrl;
  DateTime? NcupLastPausedAt;

  bool NcupLoadedOnceSent = false;
  int? NcupFirstPageTimestamp;
  int NcupStartLoadTimestamp = 0;

  // --------- Социальные / внешние хосты / схемы ---------

  final Set<String> NcupExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  final Set<String> NcupExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  final Set<String> NcupSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  // --------- UserAgent + SafeArea ---------

  String? _baseUserAgent;
  String _currentUserAgent = '';
  String? _serverUserAgent;
  String? _cachedUserAgent; // загружается из SharedPreferences при открытии по пушу
  bool _isInGoogleAuth = false;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = Colors.black;

  // --------- PostMessage bridge install timer ---------
  Timer? _parentInstallTimer;

  // --------- POPUP (window.open) ---------

  InAppWebViewController? _popupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;
  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(NcupFcmBackgroundHandler);

    NcupFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    // 1) SafeArea state (enabled + color) подхватываем из SharedPreferences
    _loadSafeAreaFromPrefs();
    // 1b) userAgent из SharedPreferences (сохранён main.dart при первом запуске)
    _loadCachedUserAgent();

    // 2) Push
    NcupInitPushAndGetToken();

    // 3) Профиль устройства -> localStorage + SharedPreferences (app_data)
    NcupDeviceProfileInstance.NcupInitialize().then((_) async {
      if (!mounted) return;
      await _updateLocalStorage();
    });

    // 4) FCM + AppsFlyer
    NcupWireForegroundPushHandlers();
    NcupBindPlatformNotificationTap();
    NcupSpyInstance.NcupStart(NcupOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _parentInstallTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState NcupState) {
    if (NcupState == AppLifecycleState.paused) {
      NcupLastPausedAt = DateTime.now();
    }
    if (NcupState == AppLifecycleState.resumed) {
      if (Platform.isIOS && NcupLastPausedAt != null) {
        final DateTime NcupNow = DateTime.now();
        final Duration NcupDrift = NcupNow.difference(NcupLastPausedAt!);
        if (NcupDrift > const Duration(minutes: 25)) {
          NcupForceReloadToLobby();
        }
      }
      NcupLastPausedAt = null;
    }
  }

  void NcupForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration NcupDuration) {
      if (!mounted) return;
      // здесь можно вернуть в MafiaHarbor/CaptainHarbor/BillHarbor при необходимости
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void NcupWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage NcupMsg) {
      if (NcupMsg.data['uri'] != null) {
        NcupNavigateTo(NcupMsg.data['uri'].toString());
      } else {
        NcupReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage NcupMsg) {
      if (NcupMsg.data['uri'] != null) {
        NcupNavigateTo(NcupMsg.data['uri'].toString());
      } else {
        NcupReturnToCurrentUrl();
      }
    });
  }

  void NcupNavigateTo(String NcupNewUrl) async {
    await NcupWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(NcupNewUrl)),
    );
  }

  void NcupReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      NcupWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(NcupCurrentUrl)),
      );
    });
  }

  Future<void> NcupInitPushAndGetToken() async {
    final FirebaseMessaging NcupFm = FirebaseMessaging.instance;
    await NcupFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    NcupPushToken = await NcupFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void NcupBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall NcupCall) async {
      if (NcupCall.method == "onNotificationTap") {
        final Map<String, dynamic> NcupPayload =
        Map<String, dynamic>.from(NcupCall.arguments);
        debugPrint("URI from platform tap: ${NcupPayload['uri']}");
        final String? NcupUriString = NcupPayload["uri"]?.toString();
        if (NcupUriString != null && !NcupUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext NcupContext) =>
                  NcupTableView(NcupUriString),
            ),
                (Route<dynamic> NcupRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // localStorage + SharedPreferences: профиль устройства
  // --------------------------------------------------------------------------

  /// Обновляем app_data в localStorage И синхронно сохраняем JSON в SharedPreferences
  Future<void> _updateLocalStorage() async {
    try {
      final Map<String, dynamic> data =
      NcupDeviceProfileInstance.NcupAsMap(NcupFcmToken: NcupPushToken);

      final String json = jsonEncode(data);

      // 1) В localStorage WebView
      await NcupWebViewController.evaluateJavascript(
        source: "localStorage.setItem('app_data', JSON.stringify($json));",
      );

      // 2) В SharedPreferences (чтобы при следующем запуске можно было восстановить)
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_data', json);

      NcupVaultInstance.NcupLoggerInstance
          .NcupLogInfo('app_data saved to localStorage & SharedPreferences: $json');
    } catch (e, st) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogError('updateLocalStorage error: $e\n$st');
    }
  }

  /// Восстанавливаем app_data из SharedPreferences обратно в localStorage
  Future<void> _restoreAppDataFromPrefsToLocalStorage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? savedJson = prefs.getString('app_data');
      if (savedJson == null || savedJson.isEmpty) {
        return;
      }

      final String js =
          "localStorage.setItem('app_data', JSON.stringify($savedJson));";

      await NcupWebViewController.evaluateJavascript(source: js);

      NcupVaultInstance.NcupLoggerInstance.NcupLogInfo(
          'app_data restored from SharedPreferences to localStorage: $savedJson');
    } catch (e, st) {
      NcupVaultInstance.NcupLoggerInstance.NcupLogError(
          '_restoreAppDataFromPrefsToLocalStorage error: $e\n$st');
    }
  }

  // --------------------------------------------------------------------------
  // UserAgent / SafeArea helpers
  // --------------------------------------------------------------------------

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google');
  }

  // ─── PostMessage bridge (включается только при safecasher == true) ───────────

  Future<void> _safeEvaluateJavascript(
    InAppWebViewController? controller, {
    required String source,
    String debugName = 'js',
  }) async {
    if (controller == null) return;
    if (!mounted) return;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      final String msg = e.toString();
      if (!msg.contains('MissingPluginException')) {
        print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
      }
    }
  }

  Future<void> _installPostMessageBridge(
    InAppWebViewController controller, {
    required String label,
  }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try { dataString = JSON.stringify(dataRaw); } catch (e) { dataString = String(dataRaw); }

              var hasBridge = !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              if (hasBridge) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') { parsed = JSON.parse(parsed); }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (hasBridge) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (parseErr) {}
            } catch (e) {}
          });
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
    InAppWebViewController? controller, {
    required String label,
  }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await _installPostMessageBridge(controller, label: label);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
    InAppWebViewController controller, {
    required String label,
  }) {
    _parentInstallTimer?.cancel();
    _parentInstallTimer = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      await _safeInstallAll(controller, label: label);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await NcupWebViewController.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          NcupDeviceProfileInstance.NcupBaseUserAgent = _baseUserAgent;
          NcupVaultInstance.NcupLoggerInstance
              .NcupLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        NcupVaultInstance.NcupLoggerInstance
            .NcupLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogWarn('Base User-Agent is null, skip UA update');
      return;
    }

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = _baseUserAgent!;
    }

    _serverUserAgent = newUa;
    NcupVaultInstance.NcupLoggerInstance
        .NcupLogInfo('Server UA calculated: $_serverUserAgent');
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (_isInGoogleAuth) {
      NcupVaultInstance.NcupLoggerInstance.NcupLogInfo(
          'Skip normal UA apply because we are in Google auth');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) return;

    try {
      await NcupWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      debugPrint('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogError('Error while setting UA "$targetUa": $e');
    }
  }

  Future<void> _addRandomToUserAgentForGoogle() async {
    const String targetUa = 'random';
    if (_currentUserAgent == targetUa && _isInGoogleAuth) return;

    try {
      await NcupWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      _isInGoogleAuth = true;
      debugPrint('[UA] GOOGLE RANDOM USER AGENT: $_currentUserAgent');
    } catch (e) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogError('Error setting RANDOM UA for Google: $e');
    }
  }

  Future<void> _restoreUserAgentAfterGoogleIfNeeded() async {
    if (!_isInGoogleAuth) return;
    _isInGoogleAuth = false;
    await _applyNormalUserAgentIfNeeded();
  }

  // Хелпер для парсинга HEX‑цвета (общий для SafeArea и prefs)
  Color _parseHexColor(String hex, {Color fallback = const Color(0xFF1A1A22)}) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final intColor = int.tryParse(value, radix: 16);
    if (intColor == null) return fallback;
    return Color(intColor);
  }

  // НОВОЕ: загрузка SafeArea из SharedPreferences при старте
  Future<void> _loadSafeAreaFromPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool enabled = prefs.getBool(NcupSafeAreaEnabledKey) ?? false;
      final String colorHex = prefs.getString(NcupSafeAreaColorKey) ?? '';

      Color bg = Colors.black;
      if (enabled) {
        if (colorHex.isNotEmpty) {
          bg = _parseHexColor(colorHex, fallback: const Color(0xFF1A1A22));
        } else {
          bg = const Color(0xFF1A1A22);
        }
      }

      if (!mounted) return;

      setState(() {
        _safeAreaEnabled = enabled;
        _safeAreaBackgroundColor = bg;
        NcupDeviceProfileInstance.NcupSafeAreaEnabled = enabled;
        NcupDeviceProfileInstance.NcupSafeAreaColor =
        enabled ? (colorHex.isNotEmpty ? colorHex : '#1A1A22') : '';
      });

      NcupVaultInstance.NcupLoggerInstance.NcupLogInfo(
          'SafeArea loaded from prefs: enabled=$enabled, color="$colorHex"');
    } catch (e, st) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogError('_loadSafeAreaFromPrefs error: $e\n$st');
    }
  }

  Future<void> _loadCachedUserAgent() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? ua = prefs.getString(NcupCachedUserAgentKey);
      if (ua != null && ua.trim().isNotEmpty) {
        _cachedUserAgent = ua.trim();
        _baseUserAgent = _cachedUserAgent;
        _currentUserAgent = _cachedUserAgent!;
        NcupDeviceProfileInstance.NcupBaseUserAgent = _cachedUserAgent;
        NcupVaultInstance.NcupLoggerInstance
            .NcupLogInfo('[UA] Loaded from SharedPreferences: $_cachedUserAgent');
      }
    } catch (e) {
      NcupVaultInstance.NcupLoggerInstance
          .NcupLogWarn('_loadCachedUserAgent error: $e');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    if (safearea == null) return;

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    Color background = safearea ? const Color(0xFF1A1A22) : Colors.black;

    if (safearea && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex, fallback: const Color(0xFF1A1A22));
    }

    setState(() {
      _safeAreaEnabled = safearea!;
      _safeAreaBackgroundColor = background;
      NcupDeviceProfileInstance.NcupSafeAreaEnabled = safearea;
      NcupDeviceProfileInstance.NcupSafeAreaColor =
      safearea ? (chosenHex ?? '#1A1A22') : '';
    });

    // НОВОЕ: сохраняем SafeArea в SharedPreferences при каждом обновлении
    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool(NcupSafeAreaEnabledKey, safearea!);
        await prefs.setString(
          NcupSafeAreaColorKey,
          NcupDeviceProfileInstance.NcupSafeAreaColor ?? '',
        );
        NcupVaultInstance.NcupLoggerInstance.NcupLogInfo(
          'SafeArea saved to prefs: enabled=$safearea, color="${NcupDeviceProfileInstance.NcupSafeAreaColor}"',
        );
      } catch (e, st) {
        NcupVaultInstance.NcupLoggerInstance
            .NcupLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();
  }

  // --------------------------------------------------------------------------
  // POPUP helpers
  // --------------------------------------------------------------------------

  InAppWebViewSettings _popupSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  void _openPopup(CreateWindowAction req, {String? urlString}) {
    setState(() {
      _popupCreateAction = req;
      _popupUrl = (urlString != null && urlString.isNotEmpty)
          ? urlString
          : req.request.url?.toString();
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      _popupWebViewController = null;
    });
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (_) {}
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          _refreshPopupCanGoBack();
        });
      } else {
        _closePopup();
      }
    } catch (_) {
      _closePopup();
    }
  }

  Widget _buildPopupOverlay() {
    if (!_isPopupVisible || (_popupUrl == null && _popupCreateAction == null)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                color: Colors.black,
                height: 48,
                child: Row(
                  children: [
                    if (_popupCanGoBack)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: _handlePopupBackPressed,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: _closePopup,
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null && _popupUrl != null)
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupSettings(),
                onWebViewCreated: (InAppWebViewController controller) async {
                  _popupWebViewController = controller;
                },
                onLoadStart: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStop: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory:
                    (controller, url, isReload) async {
                  if (url != null) {
                    setState(() {
                      _popupCurrentUrl = url.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction nav,
                    ) async {
                  final Uri? uri = nav.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (NcupKit.NcupLooksLikeBareMail(uri)) {
                    final Uri mailto = NcupKit.NcupToMailto(uri);
                    await NcupLinker.NcupOpen(NcupKit.NcupGmailize(mailto));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await NcupLinker.NcupOpen(NcupKit.NcupGmailize(uri));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (NcupIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          NcupIsBankDomain(uri))) {
                    await NcupOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  _closePopup();
                },
                onDownloadStartRequest: (controller, req) async {
                  await NcupLinker.NcupOpen(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    NcupBindPlatformNotificationTap();

    final bool NcupIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    final Color bgColor = _safeAreaEnabled
        ? _safeAreaBackgroundColor
        : (NcupIsDark ? Colors.black : Colors.white);

    final Widget webView = InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        disableDefaultErrorPage: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        allowsPictureInPictureMediaPlayback: true,
        useOnDownloadStart: true,
        javaScriptCanOpenWindowsAutomatically: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri(NcupCurrentUrl),
      ),
      onWebViewCreated: (InAppWebViewController NcupController) async {
        NcupWebViewController = NcupController;

        // Применяем кэшированный UA из SharedPreferences сразу (до загрузки страницы)
        if (_cachedUserAgent != null && _cachedUserAgent!.trim().isNotEmpty) {
          try {
            await NcupController.setSettings(
              settings: InAppWebViewSettings(userAgent: _cachedUserAgent),
            );
            debugPrint('[UA] Applied cached UA from SharedPreferences: $_cachedUserAgent');
          } catch (e) {
            NcupVaultInstance.NcupLoggerInstance
                .NcupLogWarn('Failed to apply cached UA from prefs: $e');
          }
        }

        // Инициализация UA через JS (обновляет базовый UA если не загружен из prefs)
        if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
          try {
            final ua = await NcupController.evaluateJavascript(
              source: "navigator.userAgent",
            );
            if (ua is String && ua.trim().isNotEmpty) {
              _baseUserAgent = ua.trim();
              _currentUserAgent = _baseUserAgent!;
              NcupDeviceProfileInstance.NcupBaseUserAgent = _baseUserAgent;
              debugPrint('[UA] INITIAL from JS: $_baseUserAgent');
            }
          } catch (e) {
            NcupVaultInstance.NcupLoggerInstance
                .NcupLogWarn('Failed to read navigator.userAgent: $e');
          }
        } else {
          debugPrint('[UA] INITIAL from SharedPreferences (skip JS read): $_baseUserAgent');
        }

        await _applyNormalUserAgentIfNeeded();

        // После создания WebView — актуализируем localStorage
        await _updateLocalStorage();

        // Через 6 секунд после открытия экрана — восстановление app_data из SharedPreferences
        Future<void>.delayed(const Duration(seconds: 6), () async {
          if (!mounted) return;
          await _restoreAppDataFromPrefsToLocalStorage();
        });

        // NcupPostMessage + NcupCheckoutAction — только если bridge=true


        NcupWebViewController.addJavaScriptHandler(
          handlerName: 'onServerResponse',
          callback: (List<dynamic> NcupArgs) {
            NcupVaultInstance.NcupLoggerInstance
                .NcupLogInfo("JS Args: $NcupArgs");

            try {
              dynamic first = NcupArgs.isNotEmpty ? NcupArgs[0] : null;

              if (first is List && first.isNotEmpty) {
                first = first.first;
              }

              if (first is Map) {
                final Map<dynamic, dynamic> root = first;

                // safearea + userAgent из сервера
                _updateSafeAreaFromServerPayload(root);
                _updateUserAgentFromServerPayload(root);
                _applyNormalUserAgentIfNeeded();

                // При каждом ответе сервера можно обновлять localStorage
                _updateLocalStorage();
              }

              try {
                return NcupArgs
                    .reduce((dynamic NcupV, dynamic NcupE) => NcupV + NcupE);
              } catch (_) {
                return NcupArgs.toString();
              }
            } catch (e) {
              return NcupArgs.toString();
            }
          },
        );
      },
      onLoadStart: (
          InAppWebViewController NcupController,
          Uri? NcupUri,
          ) async {
        NcupStartLoadTimestamp = DateTime.now().millisecondsSinceEpoch;

        if (NcupUri != null) {
          if (_isGoogleUrl(NcupUri)) {
            await _addRandomToUserAgentForGoogle();
          } else {
            await _restoreUserAgentAfterGoogleIfNeeded();
            await _applyNormalUserAgentIfNeeded();
          }

          if (NcupKit.NcupLooksLikeBareMail(NcupUri)) {
            try {
              await NcupController.stopLoading();
            } catch (_) {}
            final Uri NcupMailto = NcupKit.NcupToMailto(NcupUri);
            await NcupLinker.NcupOpen(
              NcupKit.NcupGmailize(NcupMailto),
            );
            return;
          }

          // банки
          if (NcupIsBankScheme(NcupUri) ||
              ((NcupUri.scheme == 'http' || NcupUri.scheme == 'https') &&
                  NcupIsBankDomain(NcupUri))) {
            try {
              await NcupController.stopLoading();
            } catch (_) {}
            await NcupOpenBank(NcupUri);
            return;
          }

          final String NcupScheme = NcupUri.scheme.toLowerCase();
          if (NcupScheme != 'http' && NcupScheme != 'https') {
            try {
              await NcupController.stopLoading();
            } catch (_) {}
          }
        }
      },
      onLoadStop: (
          InAppWebViewController NcupController,
          Uri? NcupUri,
          ) async {
        await NcupController.evaluateJavascript(
          source: "console.log('Hello from Roulette JS!');",
        );

        setState(() {
          NcupCurrentUrl = NcupUri?.toString() ?? NcupCurrentUrl;
        });

        await _restoreUserAgentAfterGoogleIfNeeded();
        await _applyNormalUserAgentIfNeeded();

        // После полной загрузки страницы обновляем localStorage
        await _updateLocalStorage();

        // И сразу тянем app_data из SharedPreferences в localStorage
        await _restoreAppDataFromPrefsToLocalStorage();

        // Устанавливаем postMessage bridge если bridge=true


        Future<void>.delayed(const Duration(seconds: 20), () {
          NcupSendLoadedOnce();
        });
      },
      shouldOverrideUrlLoading: (
          InAppWebViewController NcupController,
          NavigationAction NcupNav,
          ) async {
        final Uri? NcupUri = NcupNav.request.url;
        if (NcupUri == null) {
          return NavigationActionPolicy.ALLOW;
        }

        if (_isGoogleUrl(NcupUri)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (NcupKit.NcupLooksLikeBareMail(NcupUri)) {
          final Uri NcupMailto = NcupKit.NcupToMailto(NcupUri);
          await NcupLinker.NcupOpen(
            NcupKit.NcupGmailize(NcupMailto),
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String NcupScheme = NcupUri.scheme.toLowerCase();

        if (NcupScheme == 'mailto') {
          await NcupLinker.NcupOpen(
            NcupKit.NcupGmailize(NcupUri),
          );
          return NavigationActionPolicy.CANCEL;
        }

        if (NcupIsBankScheme(NcupUri) ||
            ((NcupScheme == 'http' || NcupScheme == 'https') &&
                NcupIsBankDomain(NcupUri))) {
          await NcupOpenBank(NcupUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (NcupScheme == 'tel') {
          await launchUrl(
            NcupUri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String NcupHost = NcupUri.host.toLowerCase();
        final bool NcupIsSocial = NcupHost.endsWith('facebook.com') ||
            NcupHost.endsWith('instagram.com') ||
            NcupHost.endsWith('twitter.com') ||
            NcupHost.endsWith('x.com');

        if (NcupIsSocial) {
          await NcupLinker.NcupOpen(NcupUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (NcupIsExternalDestination(NcupUri)) {
          final Uri NcupMapped = NcupMapExternalToHttp(NcupUri);
          await NcupLinker.NcupOpen(NcupMapped);
          return NavigationActionPolicy.CANCEL;
        }

        if (NcupScheme != 'http' && NcupScheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (
          InAppWebViewController NcupController,
          CreateWindowAction NcupReq,
          ) async {
        final Uri? NcupUrl = NcupReq.request.url;
        if (NcupUrl == null) return false;

        if (_isGoogleUrl(NcupUrl)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (NcupKit.NcupLooksLikeBareMail(NcupUrl)) {
          final Uri NcupMail = NcupKit.NcupToMailto(NcupUrl);
          await NcupLinker.NcupOpen(
            NcupKit.NcupGmailize(NcupMail),
          );
          return false;
        }

        final String NcupScheme = NcupUrl.scheme.toLowerCase();

        if (NcupScheme == 'mailto') {
          await NcupLinker.NcupOpen(
            NcupKit.NcupGmailize(NcupUrl),
          );
          return false;
        }

        if (NcupIsBankScheme(NcupUrl) ||
            ((NcupScheme == 'http' || NcupScheme == 'https') &&
                NcupIsBankDomain(NcupUrl))) {
          await NcupOpenBank(NcupUrl);
          return false;
        }

        if (NcupScheme == 'tel') {
          await launchUrl(
            NcupUrl,
            mode: LaunchMode.externalApplication,
          );
          return false;
        }

        final String NcupHost = NcupUrl.host.toLowerCase();
        final bool NcupIsSocial = NcupHost.endsWith('facebook.com') ||
            NcupHost.endsWith('instagram.com') ||
            NcupHost.endsWith('twitter.com') ||
            NcupHost.endsWith('x.com');

        if (NcupIsSocial) {
          await NcupLinker.NcupOpen(NcupUrl);
          return false;
        }

        if (NcupIsExternalDestination(NcupUrl)) {
          final Uri NcupMapped = NcupMapExternalToHttp(NcupUrl);
          await NcupLinker.NcupOpen(NcupMapped);
          return false;
        }

        // popup-логика: всё, что осталось http/https — открываем во всплывающем WebView
        if (NcupScheme == 'http' || NcupScheme == 'https') {
          _openPopup(NcupReq, urlString: NcupUrl.toString());
          return true; // говорим WebView, что создаём окно сами
        }

        return false;
      },
    );

    final Widget body = Stack(
      children: <Widget>[
        webView,
        if (NcupOverlayBusy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        _buildPopupOverlay(),
      ],
    );

    final Widget wrapped = _safeAreaEnabled ? SafeArea(child: body) : body;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: bgColor,
        body: wrapped,
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool NcupIsExternalDestination(Uri NcupUri) {
    final String NcupScheme = NcupUri.scheme.toLowerCase();
    if (NcupExternalSchemes.contains(NcupScheme)) {
      return true;
    }

    if (NcupScheme == 'http' || NcupScheme == 'https') {
      final String NcupHost = NcupUri.host.toLowerCase();
      if (NcupExternalHosts.contains(NcupHost)) {
        return true;
      }
      if (NcupHost.endsWith('t.me')) return true;
      if (NcupHost.endsWith('wa.me')) return true;
      if (NcupHost.endsWith('m.me')) return true;
      if (NcupHost.endsWith('signal.me')) return true;
      if (NcupHost.endsWith('facebook.com')) return true;
      if (NcupHost.endsWith('instagram.com')) return true;
      if (NcupHost.endsWith('twitter.com')) return true;
      if (NcupHost.endsWith('x.com')) return true;
    }

    return false;
  }

  Uri NcupMapExternalToHttp(Uri NcupUri) {
    final String NcupScheme = NcupUri.scheme.toLowerCase();

    if (NcupScheme == 'tg' || NcupScheme == 'telegram') {
      final Map<String, String> NcupQp = NcupUri.queryParameters;
      final String? NcupDomain = NcupQp['domain'];
      if (NcupDomain != null && NcupDomain.isNotEmpty) {
        return Uri.https('t.me', '/$NcupDomain', <String, String>{
          if (NcupQp['start'] != null) 'start': NcupQp['start']!,
        });
      }
      final String NcupPath = NcupUri.path.isNotEmpty ? NcupUri.path : '';
      return Uri.https(
        't.me',
        '/$NcupPath',
        NcupUri.queryParameters.isEmpty ? null : NcupUri.queryParameters,
      );
    }

    if (NcupScheme == 'whatsapp') {
      final Map<String, String> NcupQp = NcupUri.queryParameters;
      final String? NcupPhone = NcupQp['phone'];
      final String? NcupText = NcupQp['text'];
      if (NcupPhone != null && NcupPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${NcupKit.NcupDigitsOnly(NcupPhone)}',
          <String, String>{
            if (NcupText != null && NcupText.isNotEmpty) 'text': NcupText,
          },
        );
      }
      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (NcupText != null && NcupText.isNotEmpty) 'text': NcupText,
        },
      );
    }

    if (NcupScheme == 'bnl') {
      final String NcupNewPath = NcupUri.path.isNotEmpty ? NcupUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$NcupNewPath',
        NcupUri.queryParameters.isEmpty ? null : NcupUri.queryParameters,
      );
    }

    return NcupUri;
  }

  Future<void> NcupSendLoadedOnce() async {
    if (NcupLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int NcupNow = DateTime.now().millisecondsSinceEpoch;

    await NcupPostStat(
      NcupEvent: 'Loaded',
      NcupTimeStart: NcupStartLoadTimestamp,
      NcupTimeFinish: NcupNow,
      NcupUrl: NcupCurrentUrl,
      NcupAppSid: NcupSpyInstance.NcupAppsFlyerUid,
      NcupFirstPageTs: NcupFirstPageTimestamp,
    );

    NcupLoadedOnceSent = true;
  }
}