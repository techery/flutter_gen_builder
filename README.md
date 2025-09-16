# Flutter Gen Builder

Custom `build_runner` builder for enhancing existing `flutter_gen` directory that enables global localization access across all modules in a Flutter project.

## Features

- 🚀 **Automatic package enhancement** - Enhances existing `flutter_gen` directory with pubspec.yaml
- 🌍 **Global module access** - All modules can use `import 'package:flutter_gen/app_localizations.dart';`
- 📦 **Multi-language support** - Supports any number of languages dynamically
- ⚡ **Build runner integration** - Seamlessly integrates with Flutter's build system
- 🔄 **No file duplication** - Works directly with Flutter's generated files

## How it works

1. **Generates Flutter localization files** using `flutter gen-l10n`
2. **Enhances existing flutter_gen directory** in `.dart_tool/flutter_gen/` with pubspec.yaml
3. **Updates package_config.json** for main app and all modules
4. **Enables global imports** like `package:flutter_gen/app_localizations.dart`

## Dependencies

- `build: ^3.1.0` - Build system integration
- `path: ^1.8.0` - File path manipulation
- `yaml: ^3.1.0` - l10n.yaml configuration reading

## Usage

This builder is automatically used by the main client application when running:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Architecture

The builder implements the following workflow:

```
l10n.yaml → flutter gen-l10n → .dart_tool/flutter_gen/gen_l10n/*.dart
                                          ↓
                              Add pubspec.yaml to existing directory
                                          ↓
                          .dart_tool/flutter_gen/pubspec.yaml + lib/gen_l10n/*.dart
                                          ↓
                              Update package_config.json for all modules
                                          ↓
                    Enable: import 'package:flutter_gen/app_localizations.dart';
```

## Generated Structure

```
.dart_tool/flutter_gen_synthetic/
├── pubspec.yaml                    # Synthetic package metadata
└── lib/gen_l10n/
    ├── app_localizations.dart      # Main localization class
    ├── app_localizations_en.dart   # English localizations
    ├── app_localizations_es.dart   # Spanish localizations
    ├── app_localizations_ru.dart   # Russian localizations
    └── app_localizations_*.dart    # Other languages (dynamic)
```

## Benefits

- **Clean separation** - Builder logic separated from main application
- **Reusable** - Can be used in other Flutter projects
- **Maintainable** - Clear dependencies and isolated codebase
- **Efficient** - Only necessary dependencies in main application
