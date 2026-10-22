#!/bin/zsh
# Build chargebar.app with the Command Line Tools swiftc (no Xcode.app needed).
# Mirrors the Xcode target: Swift 6, strict concurrency, macOS 26.0, arm64,
# hardened runtime, ad-hoc signature.
#
#   scripts/build.sh            # Debug -> build/Debug/chargebar.app
#   scripts/build.sh release    # Release -> build/Release/chargebar.app
set -euo pipefail

root=${0:A:h:h}
config=Debug
opt=(-Onone -g -DDEBUG)
copt=(-O0 -g)
if [[ ${1:-} == release ]]; then
    config=Release
    opt=(-O)
    copt=(-O2)
fi

app="$root/build/$config/chargebar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

xcrun swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -module-name chargebar \
    "${opt[@]}" \
    -o "$app/Contents/MacOS/chargebar" \
    "$root"/chargebar/*.swift

cp "$root/chargebar/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

codesign --force --sign - --options runtime \
    --entitlements "$root/chargebar/chargebar.entitlements" \
    "$app"

echo "Built $app"

# Root helper for caps below 80% / sailing (installed separately: sudo scripts/install-helper.sh).
helper="$root/build/$config/chargebar-helper"
xcrun clang -Wall -Werror -target arm64-apple-macos26.0 "${copt[@]}" \
    -framework IOKit -framework CoreFoundation \
    -o "$helper" "$root/helper/chargebar-helper.c"
codesign --force --sign - --options runtime --identifier net.digital-shokunin.chargebar.helper "$helper"
echo "Built $helper"
