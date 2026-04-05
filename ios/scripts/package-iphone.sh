#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${IOS_DIR}/SayVibe.xcodeproj"
WORK_DIR="${IOS_DIR}/build/package"
ARCHIVE_PATH="${WORK_DIR}/SayVibe.xcarchive"
EXPORT_DIR="${WORK_DIR}/export"
DERIVED_DATA_PATH="${WORK_DIR}/DerivedData"
EXPORT_OPTIONS_PATH="${WORK_DIR}/ExportOptions.plist"

SCHEME="${SCHEME:-SayVibe}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "${DEVELOPER_DIR}" ]]; then
  echo "DEVELOPER_DIR not found: ${DEVELOPER_DIR}" >&2
  exit 1
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Project not found: ${PROJECT_PATH}" >&2
  exit 1
fi

if [[ -z "${TEAM_ID}" ]]; then
  TEAM_ID="$(
    DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT_PATH}" \
      -scheme "${SCHEME}" \
      -showBuildSettings 2>/dev/null \
      | awk '/DEVELOPMENT_TEAM =/ { print $3; exit }'
  )"
fi

TEAM_ID="$(printf '%s' "${TEAM_ID}" | tr -d '\";' | xargs)"

if [[ -z "${TEAM_ID}" ]]; then
  cat <<'EOF'
Unable to auto-detect TEAM_ID.

Please either:
1) Open Xcode and set Signing Team once, then rerun.
2) Or pass env manually:
   TEAM_ID=ABCDE12345 ./ios/scripts/package-iphone.sh

Optional env:
  SCHEME=SayVibe
  CONFIGURATION=Release
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
EOF
  exit 1
fi

echo "Using TEAM_ID: ${TEAM_ID}"

if security find-identity -v -p codesigning | grep -q "0 valid identities found"; then
  cat <<'EOF'
Warning: no local iOS code-signing identity found.
Please ensure Xcode has signed in your Apple ID and can manage certificates/profiles automatically.
EOF
fi

mkdir -p "${WORK_DIR}" "${EXPORT_DIR}"
rm -rf "${ARCHIVE_PATH}" "${DERIVED_DATA_PATH}" "${EXPORT_DIR:?}"/*

cat > "${EXPORT_OPTIONS_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>compileBitcode</key>
    <false/>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>debugging</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>thinning</key>
    <string>&lt;none&gt;</string>
</dict>
</plist>
EOF

echo "==> Archiving..."
DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  archive

echo "==> Exporting ipa..."
DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
  -allowProvisioningUpdates

IPA_PATH="$(find "${EXPORT_DIR}" -maxdepth 1 -name "*.ipa" | head -n 1)"

if [[ -z "${IPA_PATH}" ]]; then
  echo "IPA export failed: no .ipa found in ${EXPORT_DIR}" >&2
  exit 1
fi

echo
echo "Done."
echo "IPA: ${IPA_PATH}"
