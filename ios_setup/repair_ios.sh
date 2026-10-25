#!/usr/bin/env bash
# Repairs / regenerates the Flutter iOS platform folder (ios/) when Flutter says
# "Application not configured for iOS". Uses Flutter's own tooling only
# (`flutter create --platforms=ios`), never touches lib/, android/ or windows/.
#
# Run from anywhere:  bash ios_setup/repair_ios.sh      (needs Flutter on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."

required=(
  ios/Runner.xcodeproj/project.pbxproj
  ios/Runner.xcworkspace/contents.xcworkspacedata
  ios/Runner/Info.plist
  ios/Runner/AppDelegate.swift
  ios/Flutter/Debug.xcconfig
  ios/Flutter/Release.xcconfig
)

report() {
  echo "---- ls -la ios";          ls -la ios 2>/dev/null || echo "(ios/ does not exist)"
  echo "---- ls -la ios/Runner";   ls -la ios/Runner 2>/dev/null || echo "(missing)"
  echo "---- ls -la ios/Flutter";  ls -la ios/Flutter 2>/dev/null || echo "(missing)"
}

find_missing() {
  missing=()
  for f in "${required[@]}"; do [ -f "$f" ] || missing+=("$f"); done
}

echo "===== iOS folder BEFORE repair"
report
find_missing
if [ ${#missing[@]} -eq 0 ]; then
  echo "ios/ already contains every required file; nothing to regenerate."
else
  echo "Missing: ${missing[*]}"

  NAME=$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' pubspec.yaml | head -1)
  [ -n "$NAME" ] || { echo "Cannot read the project name from pubspec.yaml"; exit 1; }

  # Keep the existing bundle / package id: reuse the Android applicationId.
  APPID=""
  for g in android/app/build.gradle android/app/build.gradle.kts; do
    if [ -z "$APPID" ] && [ -f "$g" ]; then
      APPID=$(sed -n 's/.*applicationId[[:space:]=]*"\([^"]*\)".*/\1/p' "$g" | head -1)
    fi
  done
  ORG="com.example"
  if [ -n "$APPID" ] && [[ "$APPID" == *.* ]]; then ORG="${APPID%.*}"; fi
  echo "Project name: $NAME   org: $ORG   android applicationId: ${APPID:-<none>}"

  # Never delete: a broken ios/ is moved aside, then regenerated.
  BACKUP=""
  if [ -e ios ]; then
    BACKUP="ios_backup_$(date +%Y%m%d%H%M%S)"
    mv ios "$BACKUP"
    echo "Moved the incomplete ios/ to $BACKUP"
  fi

  flutter create --platforms=ios --project-name "$NAME" --org "$ORG" .

  # Make the bundle id identical to the Android id when the names differ.
  if [ -n "$APPID" ] && [ "$ORG.$NAME" != "$APPID" ]; then
    sed -i.bak "s/$ORG\.$NAME\.RunnerTests/$APPID.RunnerTests/g; s/$ORG\.$NAME;/$APPID;/g" \
      ios/Runner.xcodeproj/project.pbxproj
    rm -f ios/Runner.xcodeproj/project.pbxproj.bak
  fi

  # Keep the old display name when there was one.
  if [ -n "$BACKUP" ] && [ -f "$BACKUP/Runner/Info.plist" ] && [ -x /usr/libexec/PlistBuddy ]; then
    OLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$BACKUP/Runner/Info.plist" 2>/dev/null || true)
    if [ -n "$OLD" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $OLD" ios/Runner/Info.plist || true
    fi
  fi
fi

# Settings the app needs (idempotent): http streams + portrait/landscape.
if [ -x /usr/libexec/PlistBuddy ]; then
  P=ios/Runner/Info.plist
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$P" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$P" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations" "$P" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations array" "$P"
  for o in Portrait LandscapeLeft LandscapeRight; do
    /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations: string UIInterfaceOrientation$o" "$P"
  done
else
  echo "PlistBuddy not found (not macOS): add the Info.plist keys from IOS_BUILD.md by hand."
fi

flutter pub get   # also writes ios/Flutter/Generated.xcconfig

echo "===== iOS folder AFTER repair"
report
required+=(ios/Flutter/Generated.xcconfig)
find_missing
if [ ${#missing[@]} -ne 0 ]; then
  echo "STILL MISSING: ${missing[*]}"; exit 1
fi
echo "ios/ is a valid Flutter iOS project."
