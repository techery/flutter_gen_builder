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
        'pubspec.yaml': ['.dart_tool/flutter_gen/pubspec.yaml'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    try {
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

          // Extract locale from filename using pattern: prefix_locale.arb
          final match = RegExp(r'^[^_]+_([a-z]{2})\.arb$').firstMatch(fileName);
          if (match != null) {
            locales.add(match.group(1)!);
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

            // Extract locale from base app files
            final match = RegExp(
              r'^[^_]+_([a-z]{2})\.arb$',
            ).firstMatch(fileName);
            if (match != null) {
              locales.add(match.group(1)!);
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

          // Check if this file is for a supported locale
          final match = RegExp(r'^[^_]+_([a-z]{2})\.arb$').firstMatch(fileName);
          if (match != null && supportedLocales.contains(match.group(1))) {
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
      await _mergeLocaleFilesAuto(
        baseFiles[locale],
        extensionFiles[locale],
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
        final match = RegExp(r'^[^_]+_([a-z]{2})\.arb$').firstMatch(fileName);
        if (match != null) {
          final locale = match.group(1)!;
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
}
