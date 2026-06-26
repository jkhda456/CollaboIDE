import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ko'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Collabo IDE'**
  String get appTitle;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @tabModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get tabModel;

  /// No description provided for @tabTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get tabTools;

  /// No description provided for @tabPrompt.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get tabPrompt;

  /// No description provided for @tabAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get tabAppearance;

  /// No description provided for @tabAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get tabAbout;

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version} (build {build})'**
  String aboutVersion(String version, String build);

  /// No description provided for @openSourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Open source'**
  String get openSourceTitle;

  /// No description provided for @openSourceIntro.
  ///
  /// In en, this message translates to:
  /// **'Built with these open-source components. See the full licenses below.'**
  String get openSourceIntro;

  /// No description provided for @viewLicenses.
  ///
  /// In en, this message translates to:
  /// **'View all open-source licenses'**
  String get viewLicenses;

  /// No description provided for @systemPromptDesc.
  ///
  /// In en, this message translates to:
  /// **'System prompt sent at the start of every conversation (execution strategy). Leave empty to use the default.'**
  String get systemPromptDesc;

  /// No description provided for @usePreAssessment.
  ///
  /// In en, this message translates to:
  /// **'Use pre-assessment'**
  String get usePreAssessment;

  /// No description provided for @usePreAssessmentDesc.
  ///
  /// In en, this message translates to:
  /// **'Before replying, a sub-agent reviews your latest request and adds a one-line note on whether it should be delegated.'**
  String get usePreAssessmentDesc;

  /// No description provided for @resetDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get resetDefault;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @selectButton.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get selectButton;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get themeSystem;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @navNewProject.
  ///
  /// In en, this message translates to:
  /// **'New Project'**
  String get navNewProject;

  /// No description provided for @navOpenProject.
  ///
  /// In en, this message translates to:
  /// **'Open Project'**
  String get navOpenProject;

  /// No description provided for @noProjectTitle.
  ///
  /// In en, this message translates to:
  /// **'No project is open'**
  String get noProjectTitle;

  /// No description provided for @startNewProject.
  ///
  /// In en, this message translates to:
  /// **'Start a new project'**
  String get startNewProject;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get navCollapse;

  /// No description provided for @activityTitle.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get activityTitle;

  /// No description provided for @activityRunningLabel.
  ///
  /// In en, this message translates to:
  /// **'Running ({count})'**
  String activityRunningLabel(int count);

  /// No description provided for @activityRunningTooltip.
  ///
  /// In en, this message translates to:
  /// **'Running processes: {count}'**
  String activityRunningTooltip(int count);

  /// No description provided for @activityIdleTooltip.
  ///
  /// In en, this message translates to:
  /// **'No running processes'**
  String get activityIdleTooltip;

  /// No description provided for @newProjectTitle.
  ///
  /// In en, this message translates to:
  /// **'New Project'**
  String get newProjectTitle;

  /// No description provided for @selectParentPath.
  ///
  /// In en, this message translates to:
  /// **'Select a parent folder'**
  String get selectParentPath;

  /// No description provided for @selectPath.
  ///
  /// In en, this message translates to:
  /// **'Select folder'**
  String get selectPath;

  /// No description provided for @projectNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Project name (folder name)'**
  String get projectNameLabel;

  /// No description provided for @createLocation.
  ///
  /// In en, this message translates to:
  /// **'Location: {path}'**
  String createLocation(String path);

  /// No description provided for @pathExists.
  ///
  /// In en, this message translates to:
  /// **'A project (folder) with the same name already exists.'**
  String get pathExists;

  /// No description provided for @createFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create folder: {error}'**
  String createFailed(String error);

  /// No description provided for @nameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get nameEmpty;

  /// No description provided for @nameInvalidChars.
  ///
  /// In en, this message translates to:
  /// **'Contains invalid characters: < > : \" / \\ | ? *'**
  String get nameInvalidChars;

  /// No description provided for @nameInvalidName.
  ///
  /// In en, this message translates to:
  /// **'Invalid name.'**
  String get nameInvalidName;

  /// No description provided for @nameTrailingDot.
  ///
  /// In en, this message translates to:
  /// **'Name cannot end with a dot (.) or space.'**
  String get nameTrailingDot;

  /// No description provided for @nameReserved.
  ///
  /// In en, this message translates to:
  /// **'Reserved names cannot be used.'**
  String get nameReserved;

  /// No description provided for @connectionMethod.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get connectionMethod;

  /// No description provided for @openaiCompatible.
  ///
  /// In en, this message translates to:
  /// **'OpenAI-compatible API'**
  String get openaiCompatible;

  /// No description provided for @modelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get modelLabel;

  /// No description provided for @multimodalSupport.
  ///
  /// In en, this message translates to:
  /// **'Multimodal support'**
  String get multimodalSupport;

  /// No description provided for @multimodalSupportDesc.
  ///
  /// In en, this message translates to:
  /// **'Enable to attach images to messages with the + button. Use only with a vision-capable model.'**
  String get multimodalSupportDesc;

  /// No description provided for @reasoningEffort.
  ///
  /// In en, this message translates to:
  /// **'Attach reasoning effort option'**
  String get reasoningEffort;

  /// No description provided for @reasoningEffortDesc.
  ///
  /// In en, this message translates to:
  /// **'\"Don\'t attach\" omits reasoning_effort from the request; none/low/high are sent as-is (none disables reasoning). Use only with models/servers that support it, e.g. llama.cpp.'**
  String get reasoningEffortDesc;

  /// No description provided for @reasoningEffortOff.
  ///
  /// In en, this message translates to:
  /// **'Don\'t attach'**
  String get reasoningEffortOff;

  /// No description provided for @testConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get testConnection;

  /// No description provided for @showKey.
  ///
  /// In en, this message translates to:
  /// **'Show key'**
  String get showKey;

  /// No description provided for @hideKey.
  ///
  /// In en, this message translates to:
  /// **'Hide key'**
  String get hideKey;

  /// No description provided for @toolsDescription.
  ///
  /// In en, this message translates to:
  /// **'Tools the LLM calls via function calling. The base is fixed; you can add a general Python script (--help auto-parse) or an MCP server.'**
  String get toolsDescription;

  /// No description provided for @addTool.
  ///
  /// In en, this message translates to:
  /// **'Add tool'**
  String get addTool;

  /// No description provided for @addToolCli.
  ///
  /// In en, this message translates to:
  /// **'General Python script'**
  String get addToolCli;

  /// No description provided for @addToolCliDesc.
  ///
  /// In en, this message translates to:
  /// **'Auto-generate tool JSON by analyzing --help'**
  String get addToolCliDesc;

  /// No description provided for @addToolMcp.
  ///
  /// In en, this message translates to:
  /// **'MCP tool'**
  String get addToolMcp;

  /// No description provided for @addToolMcpDesc.
  ///
  /// In en, this message translates to:
  /// **'Control an MCP server with bundled Python to add tools'**
  String get addToolMcpDesc;

  /// No description provided for @mcpAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add MCP tool'**
  String get mcpAddTitle;

  /// No description provided for @mcpCommand.
  ///
  /// In en, this message translates to:
  /// **'Server command'**
  String get mcpCommand;

  /// No description provided for @mcpCommandHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. npx or python'**
  String get mcpCommandHint;

  /// No description provided for @mcpArgs.
  ///
  /// In en, this message translates to:
  /// **'Arguments (space-separated)'**
  String get mcpArgs;

  /// No description provided for @mcpArgsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. -y @modelcontextprotocol/server-filesystem .'**
  String get mcpArgsHint;

  /// No description provided for @nameOptional.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get nameOptional;

  /// No description provided for @toolInspect.
  ///
  /// In en, this message translates to:
  /// **'Inspect tools'**
  String get toolInspect;

  /// No description provided for @pythonNotReadyInspect.
  ///
  /// In en, this message translates to:
  /// **'Python is not ready. Select an interpreter and try again.'**
  String get pythonNotReadyInspect;

  /// No description provided for @toolInfoFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not get tool info.'**
  String get toolInfoFailed;

  /// No description provided for @toolsCount.
  ///
  /// In en, this message translates to:
  /// **'{name} tools ({count})'**
  String toolsCount(String name, int count);

  /// No description provided for @baseModuleLabel.
  ///
  /// In en, this message translates to:
  /// **'collabo_base (base)'**
  String get baseModuleLabel;

  /// No description provided for @extractPending.
  ///
  /// In en, this message translates to:
  /// **'Extracting…'**
  String get extractPending;

  /// No description provided for @viewTools.
  ///
  /// In en, this message translates to:
  /// **'View tools'**
  String get viewTools;

  /// No description provided for @pythonEnv.
  ///
  /// In en, this message translates to:
  /// **'Python environment'**
  String get pythonEnv;

  /// No description provided for @statusCheck.
  ///
  /// In en, this message translates to:
  /// **'Check status'**
  String get statusCheck;

  /// No description provided for @pythonSettings.
  ///
  /// In en, this message translates to:
  /// **'Python settings'**
  String get pythonSettings;

  /// No description provided for @pythonNotSetTitle.
  ///
  /// In en, this message translates to:
  /// **'Python not set'**
  String get pythonNotSetTitle;

  /// No description provided for @pythonNotSetBody.
  ///
  /// In en, this message translates to:
  /// **'Select an interpreter in \"Python settings\" first.'**
  String get pythonNotSetBody;

  /// No description provided for @pythonCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Python environment check'**
  String get pythonCheckTitle;

  /// No description provided for @selectPythonPrompt.
  ///
  /// In en, this message translates to:
  /// **'Select the Python interpreter to use.'**
  String get selectPythonPrompt;

  /// No description provided for @notSelected.
  ///
  /// In en, this message translates to:
  /// **'Not selected'**
  String get notSelected;

  /// No description provided for @selectPython.
  ///
  /// In en, this message translates to:
  /// **'Select Python'**
  String get selectPython;

  /// No description provided for @pythonVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get pythonVerified;

  /// No description provided for @pythonMissing.
  ///
  /// In en, this message translates to:
  /// **'No interpreter at that path.'**
  String get pythonMissing;

  /// No description provided for @pythonMissingQuestion.
  ///
  /// In en, this message translates to:
  /// **'No Python? '**
  String get pythonMissingQuestion;

  /// No description provided for @downloadFromPythonOrg.
  ///
  /// In en, this message translates to:
  /// **'Download from python.org'**
  String get downloadFromPythonOrg;

  /// No description provided for @allFiles.
  ///
  /// In en, this message translates to:
  /// **'All files'**
  String get allFiles;

  /// No description provided for @console.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get console;

  /// No description provided for @consoleStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get consoleStarting;

  /// No description provided for @consoleInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type and press Enter (e.g. y / n)'**
  String get consoleInputHint;

  /// No description provided for @consoleEnded.
  ///
  /// In en, this message translates to:
  /// **'Process has ended'**
  String get consoleEnded;

  /// No description provided for @consoleProcessExited.
  ///
  /// In en, this message translates to:
  /// **'[process exited: {code}]'**
  String consoleProcessExited(int code);

  /// No description provided for @consoleExecFailed.
  ///
  /// In en, this message translates to:
  /// **'Execution failed: {error}'**
  String consoleExecFailed(String error);

  /// No description provided for @webviewUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The WebView backend for this platform is not connected yet.'**
  String get webviewUnsupported;

  /// No description provided for @webviewInitFailed.
  ///
  /// In en, this message translates to:
  /// **'WebView initialization failed\n{error}'**
  String webviewInitFailed(String error);

  /// No description provided for @webviewRuntimeMissing.
  ///
  /// In en, this message translates to:
  /// **'Microsoft Edge WebView2 Runtime is required to display this view.\nInstall it and restart the app.'**
  String get webviewRuntimeMissing;

  /// No description provided for @webviewRuntimeDownload.
  ///
  /// In en, this message translates to:
  /// **'Download WebView2 Runtime'**
  String get webviewRuntimeDownload;

  /// No description provided for @noOpenProject.
  ///
  /// In en, this message translates to:
  /// **'No project open'**
  String get noOpenProject;

  /// No description provided for @wizardTitle.
  ///
  /// In en, this message translates to:
  /// **'Initial setup'**
  String get wizardTitle;

  /// No description provided for @wizardIntro.
  ///
  /// In en, this message translates to:
  /// **'Let\'s get Collabo IDE ready. You can change any of this later in Settings.'**
  String get wizardIntro;

  /// No description provided for @wizardStep.
  ///
  /// In en, this message translates to:
  /// **'Step {current} / {total}'**
  String wizardStep(int current, int total);

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @finish.
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get finish;

  /// No description provided for @skipSetup.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skipSetup;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
