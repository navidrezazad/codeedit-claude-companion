# Building and installing CodeEditV2

This fork ships as `CodeEditV2.app`. Day-to-day use runs from `/Applications/CodeEditV2.app`, not from Xcode's DerivedData.

## Build

```
xcodebuild -project CodeEdit.xcodeproj \
           -scheme CodeEdit \
           -configuration Debug \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation \
           -skipMacroValidation \
           build
```

The built bundle lands in the scheme's `BUILT_PRODUCTS_DIR`:

```
xcodebuild -project CodeEdit.xcodeproj -scheme CodeEdit -configuration Debug -showBuildSettings \
  | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}'
```

## Install to `/Applications`

A successful build does **not** update the app launched from Dock/Spotlight. The running app is the one in `/Applications`, so code changes are only observable after replacing it:

```
killall CodeEditV2 2>/dev/null
BUILT="$(xcodebuild -project CodeEdit.xcodeproj -scheme CodeEdit -configuration Debug -showBuildSettings \
          | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/CodeEditV2.app"
ditto "/Applications/CodeEditV2.app" "/Applications/CodeEditV2.app.backup-$(date +%Y%m%d-%H%M%S)"
rm -rf "/Applications/CodeEditV2.app"
ditto "$BUILT" "/Applications/CodeEditV2.app"
open "/Applications/CodeEditV2.app"
```

If a bug fix appears to have no effect at runtime, check the install step before anything else.
