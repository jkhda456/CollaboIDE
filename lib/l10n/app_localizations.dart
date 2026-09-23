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

  /// No description provided for @tabViewers.
  ///
  /// In en, this message translates to:
  /// **'Viewers'**
  String get tabViewers;

  /// No description provided for @tabWeb.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get tabWeb;

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

  /// No description provided for @useProjectState.
  ///
  /// In en, this message translates to:
  /// **'Send project state'**
  String get useProjectState;

  /// No description provided for @useProjectStateDesc.
  ///
  /// In en, this message translates to:
  /// **'Give the agent a short summary of the folder structure and the files tools have changed, so it does not redo work that is already done (length-limited).'**
  String get useProjectStateDesc;

  /// No description provided for @usePlanMemory.
  ///
  /// In en, this message translates to:
  /// **'Use plan memory'**
  String get usePlanMemory;

  /// No description provided for @usePlanMemoryDesc.
  ///
  /// In en, this message translates to:
  /// **'Keep the goal and plan in the project\'s .collabo/PLAYBOOK.md and send it with every turn, so the plan survives when the conversation is summarised or trimmed. Opens three tools to the agent: goal, plan and notes.'**
  String get usePlanMemoryDesc;

  /// No description provided for @useSupervisor.
  ///
  /// In en, this message translates to:
  /// **'Use supervisor'**
  String get useSupervisor;

  /// No description provided for @useSupervisorDesc.
  ///
  /// In en, this message translates to:
  /// **'Detect going in circles (the same tool or the same error repeated, rounds with no progress) and step in with stronger nudges, ending by asking you. Also sends the agent back if it tries to finish with plan steps still open.'**
  String get useSupervisorDesc;

  /// No description provided for @planCard.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get planCard;

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

  /// No description provided for @navWebSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get navWebSearch;

  /// No description provided for @conversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get conversation;

  /// No description provided for @closeProject.
  ///
  /// In en, this message translates to:
  /// **'Close project'**
  String get closeProject;

  /// No description provided for @recentProjectsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent projects'**
  String get recentProjectsTitle;

  /// No description provided for @projectBusy.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get projectBusy;

  /// No description provided for @closeBusyProjectTitle.
  ///
  /// In en, this message translates to:
  /// **'This project is still working'**
  String get closeBusyProjectTitle;

  /// No description provided for @closeBusyProjectBody.
  ///
  /// In en, this message translates to:
  /// **'{name} has a generation in progress. Closing it stops that work. Other open projects are not affected.'**
  String closeBusyProjectBody(String name);

  /// No description provided for @browserBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get browserBack;

  /// No description provided for @browserForward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get browserForward;

  /// No description provided for @browserReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get browserReload;

  /// No description provided for @browserStop.
  ///
  /// In en, this message translates to:
  /// **'Stop loading'**
  String get browserStop;

  /// No description provided for @browserNewTab.
  ///
  /// In en, this message translates to:
  /// **'New tab'**
  String get browserNewTab;

  /// No description provided for @browserCloseTab.
  ///
  /// In en, this message translates to:
  /// **'Close tab'**
  String get browserCloseTab;

  /// No description provided for @browserCloseAll.
  ///
  /// In en, this message translates to:
  /// **'Close all tabs'**
  String get browserCloseAll;

  /// No description provided for @browserCloseAgentTabs.
  ///
  /// In en, this message translates to:
  /// **'Close the agent\'s tabs'**
  String get browserCloseAgentTabs;

  /// No description provided for @browserAddressHint.
  ///
  /// In en, this message translates to:
  /// **'Search, or enter an address'**
  String get browserAddressHint;

  /// No description provided for @browserEmpty.
  ///
  /// In en, this message translates to:
  /// **'No browser tab is open'**
  String get browserEmpty;

  /// No description provided for @browserUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The web browser is not available on this platform yet.'**
  String get browserUnsupported;

  /// No description provided for @searchEngine.
  ///
  /// In en, this message translates to:
  /// **'Search engine'**
  String get searchEngine;

  /// No description provided for @searchEngineDesc.
  ///
  /// In en, this message translates to:
  /// **'Used by the agent\'s web_search tool and by the address bar above the browser. Engines are defined in the Python module collabo_web.py, so more can be added there.'**
  String get searchEngineDesc;

  /// No description provided for @browserUserAgent.
  ///
  /// In en, this message translates to:
  /// **'Browser User-Agent'**
  String get browserUserAgent;

  /// No description provided for @browserUserAgentDesc.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the platform default, which is what an ordinary browser sends and works best with sites that block automation. Applies to tabs opened from now on.'**
  String get browserUserAgentDesc;

  /// No description provided for @browserUserAgentHint.
  ///
  /// In en, this message translates to:
  /// **'Platform default'**
  String get browserUserAgentHint;

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

  /// No description provided for @activityTitleNative.
  ///
  /// In en, this message translates to:
  /// **'Tool calls'**
  String get activityTitleNative;

  /// No description provided for @activityEmptyNative.
  ///
  /// In en, this message translates to:
  /// **'No tool calls yet.'**
  String get activityEmptyNative;

  /// No description provided for @activitySelectHint.
  ///
  /// In en, this message translates to:
  /// **'Select a call to see its arguments and full result.'**
  String get activitySelectHint;

  /// No description provided for @activityArgs.
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get activityArgs;

  /// No description provided for @activityResult.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get activityResult;

  /// No description provided for @activityClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get activityClear;

  /// No description provided for @activityScopeMain.
  ///
  /// In en, this message translates to:
  /// **'main'**
  String get activityScopeMain;

  /// No description provided for @activityScopeSub.
  ///
  /// In en, this message translates to:
  /// **'sub-agent'**
  String get activityScopeSub;

  /// No description provided for @activityScopeVerify.
  ///
  /// In en, this message translates to:
  /// **'verify'**
  String get activityScopeVerify;

  /// No description provided for @activityScopeDelegate.
  ///
  /// In en, this message translates to:
  /// **'delegate'**
  String get activityScopeDelegate;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @procTitle.
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get procTitle;

  /// No description provided for @procEmpty.
  ///
  /// In en, this message translates to:
  /// **'No background processes.'**
  String get procEmpty;

  /// No description provided for @procSelectHint.
  ///
  /// In en, this message translates to:
  /// **'Select a process to view its output.'**
  String get procSelectHint;

  /// No description provided for @procStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get procStatusRunning;

  /// No description provided for @procStatusExited.
  ///
  /// In en, this message translates to:
  /// **'Exited ({code})'**
  String procStatusExited(int code);

  /// No description provided for @procStatusKilled.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get procStatusKilled;

  /// No description provided for @procStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get procStop;

  /// No description provided for @procInputHint.
  ///
  /// In en, this message translates to:
  /// **'Send input to stdin…'**
  String get procInputHint;

  /// No description provided for @procSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get procSend;

  /// No description provided for @procStdout.
  ///
  /// In en, this message translates to:
  /// **'stdout'**
  String get procStdout;

  /// No description provided for @procStderr.
  ///
  /// In en, this message translates to:
  /// **'stderr'**
  String get procStderr;

  /// No description provided for @procTerminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get procTerminal;

  /// No description provided for @procTerminalInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type into the terminal…'**
  String get procTerminalInputHint;

  /// No description provided for @procNoPty.
  ///
  /// In en, this message translates to:
  /// **'No pseudo-terminal is available, so interactive programs will not work in this session.'**
  String get procNoPty;

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

  /// No description provided for @presetLabel.
  ///
  /// In en, this message translates to:
  /// **'Preset'**
  String get presetLabel;

  /// No description provided for @presetNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Preset name'**
  String get presetNameLabel;

  /// No description provided for @addPreset.
  ///
  /// In en, this message translates to:
  /// **'Add preset'**
  String get addPreset;

  /// No description provided for @deletePreset.
  ///
  /// In en, this message translates to:
  /// **'Delete preset'**
  String get deletePreset;

  /// No description provided for @newPresetName.
  ///
  /// In en, this message translates to:
  /// **'New preset'**
  String get newPresetName;

  /// No description provided for @defaultBadge.
  ///
  /// In en, this message translates to:
  /// **'default'**
  String get defaultBadge;

  /// No description provided for @setAsDefault.
  ///
  /// In en, this message translates to:
  /// **'Set as default'**
  String get setAsDefault;

  /// No description provided for @isDefaultPreset.
  ///
  /// In en, this message translates to:
  /// **'Default preset'**
  String get isDefaultPreset;

  /// No description provided for @renamePreset.
  ///
  /// In en, this message translates to:
  /// **'Rename preset'**
  String get renamePreset;

  /// No description provided for @selectPreset.
  ///
  /// In en, this message translates to:
  /// **'Select preset'**
  String get selectPreset;

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

  /// No description provided for @openaiPrompted.
  ///
  /// In en, this message translates to:
  /// **'OpenAI-compatible (forced prompt)'**
  String get openaiPrompted;

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

  /// No description provided for @parseTextToolCalls.
  ///
  /// In en, this message translates to:
  /// **'Parse tool calls from text'**
  String get parseTextToolCalls;

  /// No description provided for @parseTextToolCallsDesc.
  ///
  /// In en, this message translates to:
  /// **'For non-standard servers that leak tool calls as body text (e.g. some MLX/local backends) instead of the tool_calls field. Off by default; standard OpenAI-compatible servers don\'t need it.'**
  String get parseTextToolCallsDesc;

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

  /// No description provided for @firstResponseTimeout.
  ///
  /// In en, this message translates to:
  /// **'First response (prefill) timeout'**
  String get firstResponseTimeout;

  /// No description provided for @firstResponseTimeoutDesc.
  ///
  /// In en, this message translates to:
  /// **'Applies only until the first response arrives. Defaults to 0 (no limit), because during prefill the server sends nothing, so a clock cannot tell \'working hard\' from \'dead connection\'. You can still stop at any time.'**
  String get firstResponseTimeoutDesc;

  /// No description provided for @secondsUnit.
  ///
  /// In en, this message translates to:
  /// **'sec'**
  String get secondsUnit;

  /// No description provided for @tokensUnit.
  ///
  /// In en, this message translates to:
  /// **'tokens'**
  String get tokensUnit;

  /// No description provided for @noLimit.
  ///
  /// In en, this message translates to:
  /// **'no limit'**
  String get noLimit;

  /// No description provided for @responseTokenBudget.
  ///
  /// In en, this message translates to:
  /// **'Token budget per response'**
  String get responseTokenBudget;

  /// No description provided for @responseTokenBudgetDesc.
  ///
  /// In en, this message translates to:
  /// **'Sets the time limit as \'long enough to produce this many tokens\'. The real limit is budget ÷ speed, so a slower model automatically gets more time. A model stuck repeating itself burns the budget regardless of speed, so it always gets caught. 0 means no limit.'**
  String get responseTokenBudgetDesc;

  /// No description provided for @tokPerSec.
  ///
  /// In en, this message translates to:
  /// **'Processing speed (tok/s)'**
  String get tokPerSec;

  /// No description provided for @tokPerSecDesc.
  ///
  /// In en, this message translates to:
  /// **'Leave empty and the app measures it from real responses. A value here wins over the measurement. Current limit for this connection'**
  String get tokPerSecDesc;

  /// No description provided for @tokPerSecAuto.
  ///
  /// In en, this message translates to:
  /// **'Empty = measure automatically (assumes 100 tok/s until then)'**
  String get tokPerSecAuto;

  /// No description provided for @tokPerSecMeasured.
  ///
  /// In en, this message translates to:
  /// **'Measured: {tps} tok/s'**
  String tokPerSecMeasured(String tps);

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

  /// No description provided for @useDefaultModel.
  ///
  /// In en, this message translates to:
  /// **'Use default model'**
  String get useDefaultModel;

  /// No description provided for @toolSubagentLabel.
  ///
  /// In en, this message translates to:
  /// **'Sub-agent (run_subagent)'**
  String get toolSubagentLabel;

  /// No description provided for @toolVerifyLabel.
  ///
  /// In en, this message translates to:
  /// **'Verify (verify_work)'**
  String get toolVerifyLabel;

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

  /// No description provided for @sandboxNotReadyInspect.
  ///
  /// In en, this message translates to:
  /// **'The tool runtime is not ready. Check the sandbox status under Settings → Tools.'**
  String get sandboxNotReadyInspect;

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

  /// No description provided for @toolToggleDesc.
  ///
  /// In en, this message translates to:
  /// **'Unchecked tools are never passed to the agent. The entry stays, so you can turn it back on any time.'**
  String get toolToggleDesc;

  /// No description provided for @toolListLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading the tool list…'**
  String get toolListLoading;

  /// No description provided for @toolNativeFixed.
  ///
  /// In en, this message translates to:
  /// **'Run by the app · always on'**
  String get toolNativeFixed;

  /// No description provided for @viewersDesc.
  ///
  /// In en, this message translates to:
  /// **'Extend the file viewer (bottom right) with a JS file. Added viewers show up in the viewer\'s mode dropdown right away.'**
  String get viewersDesc;

  /// No description provided for @viewerRulesTitle.
  ///
  /// In en, this message translates to:
  /// **'File type assignment'**
  String get viewerRulesTitle;

  /// No description provided for @viewerRulesDesc.
  ///
  /// In en, this message translates to:
  /// **'Choose which extensions each viewer handles. A viewer with extensions is used automatically for those files only; leaving the field empty makes it a fallback for files no viewer claims. Unchecking turns the viewer off entirely (built-in ones too). When several viewers claim the same extension the one higher in this list wins — drag the handle to reorder.'**
  String get viewerRulesDesc;

  /// No description provided for @viewerOrderReset.
  ///
  /// In en, this message translates to:
  /// **'Reset order'**
  String get viewerOrderReset;

  /// No description provided for @viewerReorderTooltip.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder'**
  String get viewerReorderTooltip;

  /// No description provided for @viewerUserFilesTitle.
  ///
  /// In en, this message translates to:
  /// **'User viewer files'**
  String get viewerUserFilesTitle;

  /// No description provided for @viewerExampleDesc.
  ///
  /// In en, this message translates to:
  /// **'An example viewer bundled with the app. Adding it registers it as a user viewer; copy it to start your own.'**
  String get viewerExampleDesc;

  /// No description provided for @viewerBuiltinBadge.
  ///
  /// In en, this message translates to:
  /// **'built-in'**
  String get viewerBuiltinBadge;

  /// No description provided for @viewerUserBadge.
  ///
  /// In en, this message translates to:
  /// **'user'**
  String get viewerUserBadge;

  /// No description provided for @viewersWaiting.
  ///
  /// In en, this message translates to:
  /// **'Loading the viewer list…'**
  String get viewersWaiting;

  /// No description provided for @viewersNeedProject.
  ///
  /// In en, this message translates to:
  /// **'Open a project once and the viewer list will appear here.'**
  String get viewersNeedProject;

  /// No description provided for @addViewer.
  ///
  /// In en, this message translates to:
  /// **'Add viewer'**
  String get addViewer;

  /// No description provided for @addViewerFile.
  ///
  /// In en, this message translates to:
  /// **'A single JS file'**
  String get addViewerFile;

  /// No description provided for @addViewerFileDesc.
  ///
  /// In en, this message translates to:
  /// **'A .js file containing one viewer'**
  String get addViewerFileDesc;

  /// No description provided for @addViewerFolder.
  ///
  /// In en, this message translates to:
  /// **'A folder (viewer.json)'**
  String get addViewerFolder;

  /// No description provided for @addViewerFolderDesc.
  ///
  /// In en, this message translates to:
  /// **'A viewer made of several files or WASM. The folder must contain viewer.json'**
  String get addViewerFolderDesc;

  /// No description provided for @viewersEmpty.
  ///
  /// In en, this message translates to:
  /// **'No viewers added. Only the built-in ones are used.'**
  String get viewersEmpty;

  /// No description provided for @viewSource.
  ///
  /// In en, this message translates to:
  /// **'View source'**
  String get viewSource;

  /// No description provided for @viewerFileMissing.
  ///
  /// In en, this message translates to:
  /// **'File not found'**
  String get viewerFileMissing;

  /// No description provided for @viewerReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the file.'**
  String get viewerReadFailed;

  /// No description provided for @sandboxUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This app has no sandbox runtime for this platform. Tools cannot run until you switch to System Python.'**
  String get sandboxUnavailable;

  /// No description provided for @sandboxIdle.
  ///
  /// In en, this message translates to:
  /// **'Starts when a tool first runs'**
  String get sandboxIdle;

  /// No description provided for @sandboxStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting the sandbox…'**
  String get sandboxStarting;

  /// No description provided for @sandboxRunning.
  ///
  /// In en, this message translates to:
  /// **'Sandbox running'**
  String get sandboxRunning;

  /// No description provided for @sandboxFailed.
  ///
  /// In en, this message translates to:
  /// **'Sandbox error: {error}'**
  String sandboxFailed(String error);

  /// No description provided for @navSandboxes.
  ///
  /// In en, this message translates to:
  /// **'Sandboxes'**
  String get navSandboxes;

  /// No description provided for @navSandboxesRunning.
  ///
  /// In en, this message translates to:
  /// **'{count} running'**
  String navSandboxesRunning(int count);

  /// No description provided for @sandboxNoProjects.
  ///
  /// In en, this message translates to:
  /// **'No project is open. Each open project gets its own sandbox here.'**
  String get sandboxNoProjects;

  /// No description provided for @sandboxSystemMachine.
  ///
  /// In en, this message translates to:
  /// **'System sandbox'**
  String get sandboxSystemMachine;

  /// No description provided for @sandboxSystemMachineDesc.
  ///
  /// In en, this message translates to:
  /// **'Runs tool work that belongs to no project, such as the tool list in settings. There is one per app.'**
  String get sandboxSystemMachineDesc;

  /// No description provided for @sandboxStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get sandboxStart;

  /// No description provided for @sandboxRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get sandboxRestart;

  /// No description provided for @sandboxStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get sandboxStop;

  /// No description provided for @sandboxStopTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop the sandbox'**
  String get sandboxStopTitle;

  /// No description provided for @sandboxStopBody.
  ///
  /// In en, this message translates to:
  /// **'Stopping the sandbox ends every command and terminal running in it. Files in the project folder stay as they are.'**
  String get sandboxStopBody;

  /// No description provided for @sandboxConsole.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get sandboxConsole;

  /// No description provided for @sandboxNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get sandboxNetwork;

  /// No description provided for @sandboxConsoleHint.
  ///
  /// In en, this message translates to:
  /// **'Command for the root shell'**
  String get sandboxConsoleHint;

  /// No description provided for @sandboxNotRunning.
  ///
  /// In en, this message translates to:
  /// **'The sandbox is off. Start it to use its root shell.'**
  String get sandboxNotRunning;

  /// No description provided for @sandboxNetworkEmpty.
  ///
  /// In en, this message translates to:
  /// **'No network access yet.'**
  String get sandboxNetworkEmpty;

  /// No description provided for @sandboxMountRo.
  ///
  /// In en, this message translates to:
  /// **'read-only'**
  String get sandboxMountRo;

  /// No description provided for @sandboxUptime.
  ///
  /// In en, this message translates to:
  /// **'Running since {since}'**
  String sandboxUptime(String since);

  /// No description provided for @newFile.
  ///
  /// In en, this message translates to:
  /// **'New file'**
  String get newFile;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get newFolder;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteWarn.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone (it does not go to the trash).'**
  String get deleteWarn;

  /// No description provided for @deleteFolderWarn.
  ///
  /// In en, this message translates to:
  /// **'The folder and everything in it will be removed. This cannot be undone.'**
  String get deleteFolderWarn;

  /// No description provided for @copyPath.
  ///
  /// In en, this message translates to:
  /// **'Copy full path'**
  String get copyPath;

  /// No description provided for @openWith.
  ///
  /// In en, this message translates to:
  /// **'Open with default app'**
  String get openWith;

  /// No description provided for @openInExplorer.
  ///
  /// In en, this message translates to:
  /// **'Open in file explorer'**
  String get openInExplorer;

  /// No description provided for @openPlaybook.
  ///
  /// In en, this message translates to:
  /// **'Open the plan file (.collabo/PLAYBOOK.md)'**
  String get openPlaybook;

  /// No description provided for @fileSearchPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Search file names…'**
  String get fileSearchPlaceholder;

  /// No description provided for @fileSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Search file names'**
  String get fileSearchTitle;

  /// No description provided for @contentSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Search file content'**
  String get contentSearchTitle;

  /// No description provided for @contentSearchPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Search file content…'**
  String get contentSearchPlaceholder;

  /// No description provided for @fileNone.
  ///
  /// In en, this message translates to:
  /// **'No file selected'**
  String get fileNone;

  /// No description provided for @copySelection.
  ///
  /// In en, this message translates to:
  /// **'Copy selection'**
  String get copySelection;

  /// No description provided for @fullscreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Fullscreen'**
  String get fullscreenTitle;

  /// No description provided for @fullscreenExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Exit fullscreen'**
  String get fullscreenExitTitle;

  /// No description provided for @folderEmpty.
  ///
  /// In en, this message translates to:
  /// **'(empty folder)'**
  String get folderEmpty;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @treeLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get treeLoading;

  /// No description provided for @viewerModeTitle.
  ///
  /// In en, this message translates to:
  /// **'View as'**
  String get viewerModeTitle;

  /// No description provided for @statusCheck.
  ///
  /// In en, this message translates to:
  /// **'Check status'**
  String get statusCheck;

  /// No description provided for @notSelected.
  ///
  /// In en, this message translates to:
  /// **'Not selected'**
  String get notSelected;

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

  /// No description provided for @stopChoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get stopChoiceTitle;

  /// No description provided for @stopChoiceBody.
  ///
  /// In en, this message translates to:
  /// **'What should happen to what has been done so far?'**
  String get stopChoiceBody;

  /// No description provided for @stopChoiceNote.
  ///
  /// In en, this message translates to:
  /// **'Files the tools already changed stay changed either way.'**
  String get stopChoiceNote;

  /// No description provided for @stopKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep what is done'**
  String get stopKeep;

  /// No description provided for @stopDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard it all'**
  String get stopDiscard;

  /// No description provided for @stopContinue.
  ///
  /// In en, this message translates to:
  /// **'Keep going'**
  String get stopContinue;

  /// No description provided for @checkpointTitle.
  ///
  /// In en, this message translates to:
  /// **'Create a starting point'**
  String get checkpointTitle;

  /// No description provided for @checkpointDesc.
  ///
  /// In en, this message translates to:
  /// **'Fold the conversation so far and start fresh from here. The AI will only see messages after the starting point.'**
  String get checkpointDesc;

  /// No description provided for @checkpointPlanNote.
  ///
  /// In en, this message translates to:
  /// **'The plan (PLAYBOOK) is cleared too. The previous plan is kept in .collabo/playbook-archive.'**
  String get checkpointPlanNote;

  /// No description provided for @checkpointCurrentContext.
  ///
  /// In en, this message translates to:
  /// **'Context before start'**
  String get checkpointCurrentContext;

  /// No description provided for @checkpointCompress.
  ///
  /// In en, this message translates to:
  /// **'Compress & keep the earlier content'**
  String get checkpointCompress;

  /// No description provided for @checkpointSize.
  ///
  /// In en, this message translates to:
  /// **'Compressed size'**
  String get checkpointSize;

  /// No description provided for @checkpointPreview.
  ///
  /// In en, this message translates to:
  /// **'Generate preview'**
  String get checkpointPreview;

  /// No description provided for @checkpointGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get checkpointGenerating;

  /// No description provided for @checkpointMemory.
  ///
  /// In en, this message translates to:
  /// **'Past memory'**
  String get checkpointMemory;

  /// No description provided for @checkpointCreate.
  ///
  /// In en, this message translates to:
  /// **'Create starting point'**
  String get checkpointCreate;

  /// No description provided for @checkpointModeCheckpoint.
  ///
  /// In en, this message translates to:
  /// **'Starting point'**
  String get checkpointModeCheckpoint;

  /// No description provided for @checkpointModePlan.
  ///
  /// In en, this message translates to:
  /// **'Reset plan only'**
  String get checkpointModePlan;

  /// No description provided for @planResetDesc.
  ///
  /// In en, this message translates to:
  /// **'Keep the conversation and clear only the plan (PLAYBOOK). The previous plan is kept in .collabo/playbook-archive.'**
  String get planResetDesc;

  /// No description provided for @planResetButton.
  ///
  /// In en, this message translates to:
  /// **'Reset plan'**
  String get planResetButton;

  /// No description provided for @appleFoundation.
  ///
  /// In en, this message translates to:
  /// **'Apple Foundation Models'**
  String get appleFoundation;

  /// No description provided for @appleFoundationDesc.
  ///
  /// In en, this message translates to:
  /// **'Runs on Apple\'s on-device model, so conversations stay on this device. Requires macOS or iOS 26.4+ with Apple Intelligence on.'**
  String get appleFoundationDesc;

  /// No description provided for @afmPermissive.
  ///
  /// In en, this message translates to:
  /// **'Relax the guardrails'**
  String get afmPermissive;

  /// No description provided for @afmPermissiveDesc.
  ///
  /// In en, this message translates to:
  /// **'Recommended: the default guardrails sometimes block ordinary questions.'**
  String get afmPermissiveDesc;

  /// No description provided for @afmPromptedTools.
  ///
  /// In en, this message translates to:
  /// **'Put tools in the prompt'**
  String get afmPromptedTools;

  /// No description provided for @afmPromptedToolsDesc.
  ///
  /// In en, this message translates to:
  /// **'Turn this on if the model never calls a tool. The tool list goes into the prompt and calls are read back from the answer.'**
  String get afmPromptedToolsDesc;

  /// No description provided for @afmPrewarm.
  ///
  /// In en, this message translates to:
  /// **'Load the model early'**
  String get afmPrewarm;

  /// No description provided for @afmPrewarmDesc.
  ///
  /// In en, this message translates to:
  /// **'Loads the model when you check the connection, so the first answer comes sooner.'**
  String get afmPrewarmDesc;

  /// No description provided for @afmTrimHistory.
  ///
  /// In en, this message translates to:
  /// **'Trim old turns when the context is full'**
  String get afmTrimHistory;

  /// No description provided for @afmTrimHistoryDesc.
  ///
  /// In en, this message translates to:
  /// **'When off, going over the context reports an error instead.'**
  String get afmTrimHistoryDesc;

  /// No description provided for @afmConcurrent.
  ///
  /// In en, this message translates to:
  /// **'Concurrent requests'**
  String get afmConcurrent;

  /// No description provided for @afmConcurrentDesc.
  ///
  /// In en, this message translates to:
  /// **'Empty or 0 uses the engine default.'**
  String get afmConcurrentDesc;

  /// No description provided for @folderPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder'**
  String get folderPickerTitle;

  /// No description provided for @folderPickerUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get folderPickerUp;

  /// No description provided for @folderPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No subfolders'**
  String get folderPickerEmpty;

  /// No description provided for @folderPickerFilesAppHint.
  ///
  /// In en, this message translates to:
  /// **'These folders also appear in the Files app under Collabo IDE.'**
  String get folderPickerFilesAppHint;

  /// No description provided for @sandboxUnavailableIOS.
  ///
  /// In en, this message translates to:
  /// **'The sandbox can\'t run on iOS. Chat and file editing work, but tools that run commands are unavailable.'**
  String get sandboxUnavailableIOS;

  /// No description provided for @contextWindowLabel.
  ///
  /// In en, this message translates to:
  /// **'Context size'**
  String get contextWindowLabel;

  /// No description provided for @contextWindowHelp.
  ///
  /// In en, this message translates to:
  /// **'Enter the model\'s context size in tokens. Leave empty if unknown.'**
  String get contextWindowHelp;

  /// No description provided for @contextWindowDetected.
  ///
  /// In en, this message translates to:
  /// **'{tokens} tokens'**
  String contextWindowDetected(int tokens);

  /// No description provided for @contextWindowAssumed.
  ///
  /// In en, this message translates to:
  /// **'Assuming 4096 tokens'**
  String get contextWindowAssumed;

  /// No description provided for @autoFitContext.
  ///
  /// In en, this message translates to:
  /// **'Fit to small context'**
  String get autoFitContext;

  /// No description provided for @autoFitContextDesc.
  ///
  /// In en, this message translates to:
  /// **'For models with 16K or less, send only core tools and a short prompt.'**
  String get autoFitContextDesc;

  /// No description provided for @fitBudget.
  ///
  /// In en, this message translates to:
  /// **'Uses {reserve} tokens for the reply and {input} for input.'**
  String fitBudget(int reserve, int input);

  /// No description provided for @fitPromptCompact.
  ///
  /// In en, this message translates to:
  /// **'Sends a short prompt instead of the default one.'**
  String get fitPromptCompact;

  /// No description provided for @fitPromptCustom.
  ///
  /// In en, this message translates to:
  /// **'Sends your prompt as is.'**
  String get fitPromptCustom;

  /// No description provided for @fitPromptTooLong.
  ///
  /// In en, this message translates to:
  /// **'Your prompt is too long for this model. Shorten it in Settings › Prompt.'**
  String get fitPromptTooLong;

  /// No description provided for @fitTools.
  ///
  /// In en, this message translates to:
  /// **'Shortens tool descriptions to send as many tools as possible.'**
  String get fitTools;

  /// No description provided for @fitDisabled.
  ///
  /// In en, this message translates to:
  /// **'Sub-agents, verification, plans, project summary, pre-assessment and supervisor are off.'**
  String get fitDisabled;

  /// No description provided for @fitRecommendTitle.
  ///
  /// In en, this message translates to:
  /// **'A larger model is recommended'**
  String get fitRecommendTitle;

  /// No description provided for @fitRecommendBody.
  ///
  /// In en, this message translates to:
  /// **'For long tasks, make a model with a larger context the default preset.'**
  String get fitRecommendBody;

  /// No description provided for @afmModelVersion.
  ///
  /// In en, this message translates to:
  /// **'Model version'**
  String get afmModelVersion;
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
