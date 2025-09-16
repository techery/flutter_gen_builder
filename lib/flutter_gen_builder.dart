import 'dart:convert';
import 'dart:io';
import 'package:build/build.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart' as yaml;

/// Automatic flutter_gen package enhancer
/// Enhances existing flutter_gen directory to be importable as 'package:flutter_gen/...'
Builder flutterGenBuilder(BuilderOptions options) => FlutterGenBuilder(options);

class FlutterGenBuilder implements Builder {
  final BuilderOptions options;

  FlutterGenBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
        // Create pubspec.yaml for existing flutter_gen directory
        // Only process the main pubspec.yaml, not assets/pubspec.yaml
        'pubspec.yaml': ['.dart_tool/flutter_gen/pubspec.yaml'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    try {
      // Skip processing pubspec.yaml files that are not in the root directory
      // Only process the main pubspec.yaml in the project root
      if (buildStep.inputId.path != 'pubspec.yaml') {
        log.info(
            '⏭️ Skipping ${buildStep.inputId.path} - only processing root pubspec.yaml');
        return;
      }

      log.info(
        '🚀 FlutterGenBuilder: Starting automatic flutter_gen package creation...',
      );

      // Step 1: Check if we need to merge ARB files first
      await _mergeArbFilesIfNeeded();

      // Step 2: Temporarily override l10n.yaml if needed and generate
      await _generateFlutterL10nWithOverride();

      // Step 2: Check if l10n.yaml exists and read configuration
      final l10nConfigFile = File('l10n.yaml');
      if (!l10nConfigFile.existsSync()) {
        log.info('l10n.yaml not found, skipping FlutterGenBuilder');
        return;
      }

      final l10nConfig =
          yaml.loadYaml(l10nConfigFile.readAsStringSync()) as Map;
      final outputDir = l10nConfig['output-dir'] as String? ??
          '.dart_tool/flutter_gen/gen_l10n';

      // Step 3: Check if generated files exist, if not generate them
      final generatedDir = Directory(outputDir);
      if (!generatedDir.existsSync()) {
        log.info('Generated files not found, running flutter gen-l10n...');
        await _generateFlutterL10n();

        // Check again after generation
        if (!generatedDir.existsSync()) {
          log.warning('Failed to generate localization files');
          return;
        }
      }

      // Step 4: Clean up old synthetic package if it exists
      await _cleanupOldSyntheticPackage();

      // Step 5: Enhance existing flutter_gen directory with pubspec.yaml
      await _enhanceFlutterGenPackage(buildStep, outputDir);

      // Step 6: Update package_config.json to include flutter_gen package
      await _updatePackageConfigDirect(options.config);

      // Step 7: Clean up temporary merged translations directory
      await _cleanupMergedTranslations();

      log.info(
        '✅ FlutterGenBuilder: Enhanced flutter_gen package successfully!',
      );
      log.info(
        '💡 You can now use: import \'package:flutter_gen/gen_l10n.dart\';',
      );
    } catch (e) {
      log.severe('FlutterGenBuilder failed: $e');
    }
  }

  Future<void> _enhanceFlutterGenPackage(
    BuildStep buildStep,
    String sourceDir,
  ) async {
    final sourceDirectory = Directory(sourceDir);
    if (!sourceDirectory.existsSync()) {
      log.warning('Source directory not found: $sourceDir');
      return;
    }

    // Create pubspec.yaml for existing flutter_gen directory
    final pubspecContent = _generateFlutterGenPubspec();
    final pubspecOutput = AssetId(
      buildStep.inputId.package,
      '.dart_tool/flutter_gen/pubspec.yaml',
    );
    await buildStep.writeAsString(pubspecOutput, pubspecContent);
    log.info('✅ Enhanced flutter_gen directory with pubspec.yaml');

    // No need to create lib structure - we'll use gen_l10n directly

    // Count existing .dart files for logging
    final dartFiles = <String>[];
    await for (final entity in sourceDirectory.list()) {
      if (entity is File && entity.path.endsWith('.dart')) {
        final fileName = path.basename(entity.path);
        dartFiles.add(fileName);
      }
    }

    if (dartFiles.isNotEmpty) {
      log.info('📦 Found ${dartFiles.length} existing localization files:');
      for (final file in dartFiles) {
        log.info('  - $file');
      }
    } else {
      log.warning('⚠️ No .dart files found in $sourceDir');
    }
  }

  /// Clean up old synthetic package if it exists
  Future<void> _cleanupOldSyntheticPackage() async {
    try {
      final syntheticDir = Directory('.dart_tool/flutter_gen_synthetic');
      if (syntheticDir.existsSync()) {
        await syntheticDir.delete(recursive: true);
        log.info('🧹 Cleaned up old synthetic package directory');
      }
    } catch (e) {
      log.warning('Failed to clean up old synthetic package: $e');
    }
  }

  /// Generate Flutter localization files with optional l10n.yaml override
  Future<void> _generateFlutterL10nWithOverride() async {
    final overrideArbDir = options.config['override_arb_dir'] as String?;

    if (overrideArbDir != null) {
      await _generateWithL10nOverride(overrideArbDir);
    } else {
      await _generateFlutterL10n();
    }
  }

  /// Generate with temporary l10n.yaml override
  Future<void> _generateWithL10nOverride(String overrideArbDir) async {
    try {
      log.info('📝 Generating Flutter localization files with override...');
      log.info('📋 Override arb-dir: $overrideArbDir');

      // Ensure override directory exists
      final overrideDir = Directory(overrideArbDir);
      if (!await overrideDir.exists()) {
        await overrideDir.create(recursive: true);
        log.info('📁 Created override directory: $overrideArbDir');
      }

      // Read current l10n.yaml
      final l10nFile = File('l10n.yaml');
      String? originalContent;

      if (await l10nFile.exists()) {
        originalContent = await l10nFile.readAsString();

        // Create modified content
        final lines = originalContent.split('\n');
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].startsWith('arb-dir:')) {
            lines[i] = 'arb-dir: $overrideArbDir';
            break;
          }
        }

        // Write modified l10n.yaml
        await l10nFile.writeAsString(lines.join('\n'));
        log.info('📝 Temporarily updated l10n.yaml arb-dir');
      }

      // Generate localization files
      await _generateFlutterL10n();

      // Restore original l10n.yaml
      if (originalContent != null) {
        await l10nFile.writeAsString(originalContent);
        log.info('📝 Restored original l10n.yaml');
      }
    } catch (e) {
      log.warning('Failed to generate with l10n override: $e');

      // Try to restore original l10n.yaml on error
      final l10nFile = File('l10n.yaml');
      if (await l10nFile.exists()) {
        // This is a best effort restoration
        await _generateFlutterL10n();
      }
    }
  }

  /// Generate Flutter localization files using flutter gen-l10n
  Future<void> _generateFlutterL10n() async {
    try {
      log.info('📝 Generating Flutter localization files...');
      final result = await Process.run(
          'flutter',
          [
            'gen-l10n',
          ],
          workingDirectory: Directory.current.path);

      if (result.exitCode == 0) {
        log.info('✅ Flutter localization files generated successfully');
      } else {
        log.warning(
          '⚠️ Flutter gen-l10n completed with warnings: ${result.stderr}',
        );
      }
    } catch (e) {
      log.warning('Failed to run flutter gen-l10n: $e');
    }
  }

  /// Update package_config.json for main app and configured packages
  Future<void> _updatePackageConfigDirect(Map<String, dynamic> config) async {
    try {
      final currentDir = Directory.current.absolute.path;
      final flutterGenPackagePath = '$currentDir/.dart_tool/flutter_gen';

      // Update main app package_config.json
      await _updateSinglePackageConfig(
        '.dart_tool/package_config.json',
        flutterGenPackagePath,
      );

      // Get update configuration from build.yaml
      final updatePackages = config['update_packages'];
      final updatePackagesMap = updatePackages is Map
          ? Map<String, dynamic>.from(updatePackages)
          : null;

      if (updatePackagesMap != null) {
        // Update modules based on configuration
        final modules = updatePackagesMap['modules'];
        final modulesMap =
            modules is Map ? Map<String, dynamic>.from(modules) : null;
        if (modulesMap != null) {
          await _updateModulesFromConfig(modulesMap, flutterGenPackagePath);
        }

        // Update configured sibling apps
        final apps = updatePackagesMap['apps'];
        final appsList = apps is List ? apps.cast<String>() : null;
        if (appsList != null) {
          await _updateConfiguredApps(appsList, flutterGenPackagePath);
        }
      } else {
        // Fallback to old behavior if no configuration provided
        log.info(
          '📋 No update_packages configuration found, using default behavior',
        );
        await _updateAllModules(flutterGenPackagePath);
        await _updateSiblingApps(flutterGenPackagePath);
      }
    } catch (e) {
      log.warning('Failed to update package configs: $e');
    }
  }

  /// Update a single package_config.json file
  Future<void> _updateSinglePackageConfig(
    String configPath,
    String flutterGenPackagePath,
  ) async {
    try {
      final packageConfigFile = File(configPath);

      if (!packageConfigFile.existsSync()) {
        log.warning('package_config.json not found: $configPath');
        return;
      }

      // Read current package config
      final packageConfigContent = await packageConfigFile.readAsString();
      final packageConfig =
          jsonDecode(packageConfigContent) as Map<String, dynamic>;
      final packages = packageConfig['packages'] as List<dynamic>;

      // Remove existing flutter_gen entry if it exists
      packages.removeWhere((pkg) => pkg['name'] == 'flutter_gen');

      // Add flutter_gen package - point directly to gen_l10n directory
      packages.add({
        'name': 'flutter_gen',
        'rootUri': 'file://$flutterGenPackagePath',
        'packageUri': 'gen_l10n/',
        'languageVersion': '3.0',
      });

      // Sort packages by name for consistency
      packages.sort(
        (a, b) => (a['name'] as String).compareTo(b['name'] as String),
      );

      // Write updated package config
      final updatedConfig = const JsonEncoder.withIndent(
        '  ',
      ).convert(packageConfig);
      await packageConfigFile.writeAsString(updatedConfig);
    } catch (e) {
      log.warning('Failed to update package config $configPath: $e');
    }
  }

  /// Update modules based on configuration from build.yaml
  Future<void> _updateModulesFromConfig(
    Map<String, dynamic> modulesConfig,
    String flutterGenPackagePath,
  ) async {
    try {
      final updateAll = modulesConfig['update_all'] as bool? ?? false;

      if (updateAll) {
        log.info('📋 Updating ALL modules (update_all: true)');
        await _updateAllModules(flutterGenPackagePath);
      } else {
        // Check for specific modules list (old format)
        final specificModules = modulesConfig['specific'];
        final modulesList =
            specificModules is List ? specificModules.cast<String>() : null;

        if (modulesList != null && modulesList.isNotEmpty) {
          log.info('📋 Updating specific modules: ${modulesList.join(', ')}');
          await _updateSpecificModules(modulesList, flutterGenPackagePath);
        } else {
          // Check for configured modules with custom paths (new format)
          final configuredModules = <String, dynamic>{};
          for (final entry in modulesConfig.entries) {
            if (entry.key != 'update_all' && entry.key != 'specific') {
              configuredModules[entry.key] = entry.value;
            }
          }

          if (configuredModules.isNotEmpty) {
            log.info(
                '📋 Updating configured modules: ${configuredModules.keys.join(', ')}');
            await _updateConfiguredModules(
                configuredModules, flutterGenPackagePath);
          } else {
            log.info('📋 No modules configured for update');
          }
        }
      }
    } catch (e) {
      log.warning('Failed to update modules from config: $e');
    }
  }

  /// Update package_config.json for specific modules
  Future<void> _updateSpecificModules(
    List<String> moduleNames,
    String flutterGenPackagePath,
  ) async {
    try {
      for (final moduleName in moduleNames) {
        final moduleDir = Directory('../modules/$moduleName');
        if (moduleDir.existsSync()) {
          final modulePackageConfig = File(
            path.join(moduleDir.path, '.dart_tool/package_config.json'),
          );

          if (modulePackageConfig.existsSync()) {
            await _updateSinglePackageConfig(
              modulePackageConfig.path,
              flutterGenPackagePath,
            );
            log.info('📦 Updated package_config.json for module: $moduleName');
          } else {
            log.warning(
              '⚠️  package_config.json not found for module: $moduleName',
            );
          }
        } else {
          log.warning('⚠️  Module directory not found: $moduleName');
        }
      }
    } catch (e) {
      log.warning('Failed to update specific modules: $e');
    }
  }

  /// Update package_config.json for configured modules with custom paths
  Future<void> _updateConfiguredModules(
    Map<String, dynamic> modulesConfig,
    String flutterGenPackagePath,
  ) async {
    try {
      for (final entry in modulesConfig.entries) {
        final moduleName = entry.key;
        final moduleConfig = entry.value;

        // Get custom path or use default
        String modulePath;
        if (moduleConfig is Map && moduleConfig.containsKey('path')) {
          modulePath = moduleConfig['path'] as String;
        } else {
          // Default path for backward compatibility
          modulePath = '../modules/$moduleName';
        }

        final moduleDir = Directory(modulePath);
        if (moduleDir.existsSync()) {
          final modulePackageConfig = File(
            path.join(moduleDir.path, '.dart_tool/package_config.json'),
          );

          if (modulePackageConfig.existsSync()) {
            await _updateSinglePackageConfig(
              modulePackageConfig.path,
              flutterGenPackagePath,
            );
            log.info(
                '📦 Updated package_config.json for module: $moduleName (path: $modulePath)');
          } else {
            log.warning(
              '⚠️  package_config.json not found for module: $moduleName (path: $modulePath)',
            );
          }
        } else {
          log.warning(
              '⚠️  Module directory not found: $moduleName (path: $modulePath)');
        }
      }
    } catch (e) {
      log.warning('Failed to update configured modules: $e');
    }
  }

  /// Update package_config.json for configured sibling apps
  Future<void> _updateConfiguredApps(
    List<String> appNames,
    String flutterGenPackagePath,
  ) async {
    try {
      final currentDirName = path.basename(Directory.current.path);
      log.info('📋 Updating configured apps: ${appNames.join(', ')}');

      for (final appName in appNames) {
        // Skip the current app
        if (appName == currentDirName) {
          log.info('⏩ Skipping current app: $appName');
          continue;
        }

        final siblingAppDir = Directory('../$appName');
        if (siblingAppDir.existsSync()) {
          final siblingPackageConfig = File(
            path.join(siblingAppDir.path, '.dart_tool/package_config.json'),
          );

          if (siblingPackageConfig.existsSync()) {
            await _updateSinglePackageConfig(
              siblingPackageConfig.path,
              flutterGenPackagePath,
            );
            log.info(
              '📦 Updated package_config.json for sibling app: $appName',
            );
          } else {
            log.warning('⚠️  package_config.json not found for app: $appName');
          }
        } else {
          log.warning('⚠️  App directory not found: $appName');
        }
      }
    } catch (e) {
      log.warning('Failed to update configured sibling apps: $e');
    }
  }

  /// Update package_config.json for all modules (fallback behavior)
  Future<void> _updateAllModules(String flutterGenPackagePath) async {
    try {
      final modulesDir = Directory('../modules');
      if (modulesDir.existsSync()) {
        await for (final moduleEntity in modulesDir.list()) {
          if (moduleEntity is Directory) {
            final moduleName = path.basename(moduleEntity.path);
            final modulePackageConfig = File(
              path.join(moduleEntity.path, '.dart_tool/package_config.json'),
            );

            if (modulePackageConfig.existsSync()) {
              await _updateSinglePackageConfig(
                modulePackageConfig.path,
                flutterGenPackagePath,
              );
              log.info(
                '📦 Updated package_config.json for module: $moduleName',
              );
            }
          }
        }
      }
    } catch (e) {
      log.warning('Failed to update all modules: $e');
    }
  }

  /// Update package_config.json for sibling apps (fallback behavior)
  Future<void> _updateSiblingApps(String flutterGenPackagePath) async {
    try {
      final currentDirName = path.basename(Directory.current.path);
      final parentDir = Directory('..');

      // Dynamically scan for sibling app directories
      if (parentDir.existsSync()) {
        await for (final entity in parentDir.list()) {
          if (entity is Directory) {
            final appName = path.basename(entity.path);

            // Skip the current app
            if (appName == currentDirName) continue;

            // Skip non-app directories (modules, tools, etc.)
            if (appName == 'modules' || appName == 'tools') continue;

            // Check if this looks like an app directory (has pubspec.yaml)
            final pubspecFile = File(path.join(entity.path, 'pubspec.yaml'));
            if (!pubspecFile.existsSync()) continue;

            final siblingPackageConfig = File(
              path.join(entity.path, '.dart_tool/package_config.json'),
            );

            if (siblingPackageConfig.existsSync()) {
              await _updateSinglePackageConfig(
                siblingPackageConfig.path,
                flutterGenPackagePath,
              );
              log.info(
                '📦 Updated package_config.json for sibling app: $appName',
              );
            }
          }
        }
      }
    } catch (e) {
      log.warning('Failed to update sibling apps package configs: $e');
    }
  }

  String _generateFlutterGenPubspec() {
    return '''
name: flutter_gen
description: Enhanced flutter_gen package for automatic localization
version: 1.0.0
publish_to: none
''';
  }

  /// Check if we need to merge ARB files (for app extensions like app2)
  Future<void> _mergeArbFilesIfNeeded() async {
    try {
      // Get translations path from configuration
      final translationsPath = options.config['translations_path'] as String?;

      if (translationsPath == null) {
        log.severe('❌ translations_path is required in build.yaml');
        log.info(
          '💡 Add translations_path: ".resources/translations" to your build.yaml',
        );
        return;
      }

      // Check if we have local ARB files
      final translationsDir = Directory(translationsPath);
      if (!translationsDir.existsSync()) {
        return; // No translations directory
      }

      // Get configuration from build.yaml
      final baseApp = options.config['base_app'] as String?;

      // Scan all ARB files to understand the structure
      final arbInfo = await _scanArbFiles(translationsPath, baseApp);

      if (arbInfo['supportedLocales'].isEmpty) {
        log.warning('No supported locales found');
        return;
      }

      final supportedLocales = arbInfo['supportedLocales'] as List<String>;
      final hasExtensions = arbInfo['hasExtensions'] as bool;
      final baseAppTranslations = arbInfo['baseAppPath'] as String?;

      log.info('📋 Detected locales: ${supportedLocales.join(', ')}');

      if (baseApp != null && baseAppTranslations != null) {
        log.info('📋 Using base app: $baseApp');
        // Ensure base app has package_config.json
        await _ensureBaseAppDependencies(baseApp);
      }

      if (baseApp == null) {
        // No base app - just copy local translations to merged_translations
        log.info('📋 No base app configured, copying local translations...');
        await _copyLocalTranslations(
          translationsPath,
          '.dart_tool/merged_translations',
          supportedLocales,
        );
      } else if (!hasExtensions) {
        // No extensions - just copy base app translations to merged_translations
        log.info('📋 No extensions found, copying base app translations...');
        await _copyLocalTranslations(
          baseAppTranslations!,
          '.dart_tool/merged_translations',
          supportedLocales,
        );
      } else {
        // Extensions found - merge them with base app
        log.info(
          '🔄 Found extension ARB files, merging with base app translations...',
        );
        await _mergeAllArbFiles(
          baseAppPath: baseAppTranslations!,
          extensionPath: translationsPath,
          outputPath: '.dart_tool/merged_translations',
          supportedLocales: supportedLocales,
        );
      }

      log.info('✅ ARB files merged successfully');
    } catch (e) {
      log.warning('Failed to merge ARB files: $e');
    }
  }

  /// Ensure base app has dependencies and package_config.json
  Future<void> _ensureBaseAppDependencies(String baseApp) async {
    try {
      final baseAppDir = Directory('../$baseApp');
      if (!baseAppDir.existsSync()) {
        log.warning('Base app directory not found: ../$baseApp');
        return;
      }

      final packageConfigFile = File(
        '../$baseApp/.dart_tool/package_config.json',
      );
      if (!packageConfigFile.existsSync()) {
        log.info(
          '📦 Base app missing package_config.json, running flutter pub get...',
        );

        final result = await Process.run(
            'flutter',
            [
              'pub',
              'get',
            ],
            workingDirectory: baseAppDir.path);

        if (result.exitCode == 0) {
          log.info('✅ Successfully ran flutter pub get in base app: $baseApp');
        } else {
          log.warning(
            '⚠️ Failed to run flutter pub get in base app: ${result.stderr}',
          );
        }
      } else {
        log.info('✅ Base app $baseApp already has package_config.json');
      }
    } catch (e) {
      log.warning('Failed to ensure base app dependencies: $e');
    }
  }

  /// Scan ARB files and determine structure automatically
  Future<Map<String, dynamic>> _scanArbFiles(
    String translationsPath,
    String? baseApp,
  ) async {
    final result = <String, dynamic>{
      'supportedLocales': <String>[],
      'hasExtensions': false,
      'baseAppPath': null,
    };

    final locales = <String>{};
    final localArbFiles = <String>[];

    // Scan local translations directory
    final translationsDir = Directory(translationsPath);
    if (translationsDir.existsSync()) {
      await for (final file in translationsDir.list()) {
        if (file is File && file.path.endsWith('.arb')) {
          final fileName = path.basename(file.path);
          localArbFiles.add(fileName);

          // Extract locale from filename using patterns: prefix_locale.arb or prefix_locale_REGION.arb
          final locale = _extractLocaleFromFileName(fileName);
          if (locale != null) {
            locales.add(locale);
          }
        }
      }
    }

    // Scan base app translations if configured
    String? baseAppTranslations;
    final baseArbFiles = <String>[];

    if (baseApp != null) {
      baseAppTranslations = '../$baseApp/$translationsPath';
      final baseDir = Directory(baseAppTranslations);

      if (baseDir.existsSync()) {
        result['baseAppPath'] = baseAppTranslations;

        await for (final file in baseDir.list()) {
          if (file is File && file.path.endsWith('.arb')) {
            final fileName = path.basename(file.path);
            baseArbFiles.add(fileName);

            // Extract locale from base app files using patterns: prefix_locale.arb or prefix_locale_REGION.arb
            final locale = _extractLocaleFromFileName(fileName);
            if (locale != null) {
              locales.add(locale);
            }
          }
        }
      }
    }

    // Determine if we have extensions by checking if local files exist
    result['hasExtensions'] = localArbFiles.isNotEmpty;
    result['supportedLocales'] = locales.toList()..sort();

    log.info(
      '📋 Found ${localArbFiles.length} local ARB files: ${localArbFiles.join(', ')}',
    );
    if (baseArbFiles.isNotEmpty) {
      log.info(
        '📋 Found ${baseArbFiles.length} base ARB files: ${baseArbFiles.join(', ')}',
      );
    }

    log.info('📋 Detected locales: ${locales.join(', ')}');

    return result;
  }

  /// Copy local translations to output directory (works with any ARB file names)
  Future<void> _copyLocalTranslations(
    String sourcePath,
    String outputPath,
    List<String> supportedLocales,
  ) async {
    try {
      // Ensure output directory exists
      final outputDir = Directory(outputPath);
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      final sourceDir = Directory(sourcePath);
      if (!sourceDir.existsSync()) {
        log.warning('⚠️ Source directory not found: $sourcePath');
        return;
      }

      // Copy all ARB files that match supported locales
      await for (final file in sourceDir.list()) {
        if (file is File && file.path.endsWith('.arb')) {
          final fileName = path.basename(file.path);

          // Check if this file is for a supported locale using patterns: prefix_locale.arb or prefix_locale_REGION.arb
          final locale = _extractLocaleFromFileName(fileName);
          if (locale != null &&
              supportedLocales.any((supportedLocale) =>
                  _localeMatches(locale, supportedLocale))) {
            final outputPath = path.join(outputDir.path, fileName);
            await file.copy(outputPath);
            log.info('📋 Copied $fileName to output directory');
          }
        }
      }

      log.info('✅ Local translations copied successfully');
    } catch (e) {
      log.warning('❌ Error copying local translations: $e');
      rethrow;
    }
  }

  /// Merge all ARB files automatically (works with any ARB file names)
  Future<void> _mergeAllArbFiles({
    required String baseAppPath,
    required String extensionPath,
    required String outputPath,
    required List<String> supportedLocales,
  }) async {
    log.info('🔄 Starting automatic ARB file merging...');

    // Ensure output directory exists
    final outputDir = Directory(outputPath);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    // Get all ARB files from both directories
    final baseFiles = await _getArbFilesByLocale(baseAppPath);
    final extensionFiles = await _getArbFilesByLocale(extensionPath);

    for (final locale in supportedLocales) {
      // Find matching files for this locale (exact match or fallback)
      final baseFile = _findMatchingFile(baseFiles, locale);
      final extensionFile = _findMatchingFile(extensionFiles, locale);

      log.info('🔄 Processing locale: $locale');
      if (baseFile != null) {
        log.info('   - Base file: ${path.basename(baseFile)}');
      }
      if (extensionFile != null) {
        log.info('   - Extension file: ${path.basename(extensionFile)}');
      }

      await _mergeLocaleFilesAuto(
        baseFile,
        extensionFile,
        outputPath,
        locale,
      );
    }

    log.info('✅ Automatic ARB file merging completed!');
  }

  /// Get ARB files grouped by locale
  Future<Map<String, String?>> _getArbFilesByLocale(
    String directoryPath,
  ) async {
    final result = <String, String?>{};
    final directory = Directory(directoryPath);

    if (!directory.existsSync()) {
      return result;
    }

    await for (final file in directory.list()) {
      if (file is File && file.path.endsWith('.arb')) {
        final fileName = path.basename(file.path);
        final locale = _extractLocaleFromFileName(fileName);
        if (locale != null) {
          result[locale] = file.path;
        }
      }
    }

    return result;
  }

  /// Merge ARB files for a specific locale automatically
  Future<void> _mergeLocaleFilesAuto(
    String? baseArbPath,
    String? extensionArbPath,
    String outputPath,
    String locale,
  ) async {
    try {
      Map<String, dynamic> mergedArb = {};

      // Read base ARB file if exists
      if (baseArbPath != null) {
        final baseArbFile = File(baseArbPath);
        if (await baseArbFile.exists()) {
          final baseContent = await baseArbFile.readAsString();
          final baseArb = jsonDecode(baseContent) as Map<String, dynamic>;
          mergedArb.addAll(baseArb);
          log.info(
            '📖 Loaded base ARB for $locale: ${baseArb.keys.where((k) => !k.startsWith('@')).length} keys',
          );
        }
      }

      // Read extension ARB file if exists
      if (extensionArbPath != null) {
        final extensionArbFile = File(extensionArbPath);
        if (await extensionArbFile.exists()) {
          final extensionContent = await extensionArbFile.readAsString();
          final extensionArb =
              jsonDecode(extensionContent) as Map<String, dynamic>;

          final overriddenKeys = extensionArb.keys
              .where(
                (key) => !key.startsWith('@') && mergedArb.containsKey(key),
              )
              .toList();
          final newKeys = extensionArb.keys
              .where(
                (key) => !key.startsWith('@') && !mergedArb.containsKey(key),
              )
              .toList();

          // Merge extension translations (extension overrides base)
          mergedArb.addAll(extensionArb);

          log.info(
            '📖 Loaded extension ARB for $locale: ${extensionArb.keys.where((k) => !k.startsWith('@')).length} keys',
          );
          if (overriddenKeys.isNotEmpty) {
            log.info('   - Overridden keys: ${overriddenKeys.length}');
          }
          if (newKeys.isNotEmpty) {
            log.info('   - New keys: ${newKeys.length}');
          }
        }
      }

      if (mergedArb.isEmpty) {
        log.warning('⚠️ No ARB data found for locale $locale');
        return;
      }

      // Update context to indicate merged nature
      mergedArb['@@context'] = 'Merged translations: Base App + Extensions';

      // Use the first available filename pattern for output
      String outputFileName;
      if (baseArbPath != null) {
        // Use base app filename as-is
        outputFileName = path.basename(baseArbPath);
      } else if (extensionArbPath != null) {
        // Convert extension name to a generic base name (e.g., app2_en.arb -> base_en.arb)
        final extName = path.basename(extensionArbPath);
        outputFileName = extName.replaceFirst(RegExp(r'^[^_]+_'), 'base_');
      } else {
        // Last resort fallback
        outputFileName = 'base_$locale.arb';
      }

      // Write merged ARB file
      const encoder = JsonEncoder.withIndent('  ');
      final mergedContent = encoder.convert(mergedArb);
      final outputArbPath = path.join(outputPath, outputFileName);
      final outputFile = File(outputArbPath);
      await outputFile.writeAsString(mergedContent);

      log.info(
        '📝 Merged ARB for $locale: ${mergedArb.keys.where((k) => !k.startsWith('@')).length} total keys',
      );
      log.info('   - Output: $outputArbPath');
    } catch (e) {
      log.warning('❌ Error merging locale $locale: $e');
      rethrow;
    }
  }

  /// Clean up temporary merged translations directory
  Future<void> _cleanupMergedTranslations() async {
    try {
      final mergedTranslationsDir = Directory('.dart_tool/merged_translations');
      if (mergedTranslationsDir.existsSync()) {
        await mergedTranslationsDir.delete(recursive: true);
        log.info('🧹 Cleaned up temporary merged translations directory');
      }
    } catch (e) {
      log.warning('Failed to clean up merged translations directory: $e');
    }
  }

  /// Extract locale from ARB filename
  /// Supports patterns: prefix_locale.arb and prefix_locale_REGION.arb
  /// Examples: app_de.arb -> de, app_de_DE.arb -> de_DE
  String? _extractLocaleFromFileName(String fileName) {
    final match =
        RegExp(r'^[^_]+_([a-z]{2}(?:_[A-Z]{2})?)\.arb$').firstMatch(fileName);
    return match?.group(1);
  }

  /// Check if a locale matches a supported locale (handles fallback from region-specific to language-only)
  /// Examples: de_DE matches de, en_US matches en
  bool _localeMatches(String fileLocale, String supportedLocale) {
    if (fileLocale == supportedLocale) return true;

    // If file locale has region (e.g., de_DE) and supported locale is language-only (e.g., de)
    if (fileLocale.contains('_') && !supportedLocale.contains('_')) {
      final fileLanguage = fileLocale.split('_')[0];
      return fileLanguage == supportedLocale;
    }

    return false;
  }

  /// Find a matching file for a locale, with fallback logic
  /// First tries exact match, then falls back to language-only match
  String? _findMatchingFile(Map<String, String?> files, String targetLocale) {
    // First try exact match
    if (files.containsKey(targetLocale)) {
      return files[targetLocale];
    }

    // Then try fallback: if target is language-only (e.g., 'de'), look for region-specific (e.g., 'de_DE')
    if (!targetLocale.contains('_')) {
      for (final fileLocale in files.keys) {
        if (fileLocale.startsWith('${targetLocale}_')) {
          return files[fileLocale];
        }
      }
    }

    return null;
  }
}
