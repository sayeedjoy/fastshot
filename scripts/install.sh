#!/bin/zsh
# Build FastShot (Release), replace the installed copy, and remove every stale build so only one app exists.
#
# Every build is signed with the same local certificate ("FastShot Local Signing", created on first run),
# so macOS keeps the Screen Recording permission across rebuilds: approve it once, never again.
# macOS never lets a script grant that permission itself; the first run opens the prompt for you.
#
#   ./scripts/install.sh                     build, install, relaunch
#   ./scripts/install.sh --reset-permission  forget the old permission entry and ask again
set -euo pipefail
cd "${0:A:h}/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE_ID=com.zerox.FastShot
IDENTITY="FastShot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DEST="$HOME/Applications/FastShot.app"
BUILT=.build-xcode/Build/Products/Release/FastShot.app
ask_permission=false
[[ "${1:-}" == "--reset-permission" ]] && ask_permission=true

# One-time: a self-signed code-signing certificate that only lives in your login keychain.
if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Creating the '$IDENTITY' certificate (one time)…"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" -passout pass:fastshot -out "$tmp/id.p12" 2>/dev/null
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P fastshot -T /usr/bin/codesign >/dev/null
  ask_permission=true # the signature changes this once, so the old permission entry no longer matches
fi

xcodebuild -project FastShot.xcodeproj -scheme FastShot -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build-xcode CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build -quiet 2>&1 | grep -v "\[MT\]" || true
[[ -d "$BUILT" ]] || { echo "Build failed." >&2; exit 1; }

# Quit the running copy (gracefully, then forcefully) before replacing it.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -x FastShot >/dev/null || break; sleep 0.2; done
pkill -x FastShot 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$DEST"

# Remove old build products so Spotlight and Launch Services can't pick them.
stale=("$BUILT" .build-xcode/Build/Products/Debug/FastShot.app $HOME/Library/Developer/Xcode/DerivedData/FastShot-*/Build/Products/*/FastShot.app(N))
for app in $stale; do
  [[ -e "$app" ]] || continue
  "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  rm -rf "$app"
done
"$LSREGISTER" -f "$DEST"

if $ask_permission; then
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  open "$DEST" --args --request-screen-access
  echo "Installed $DEST"
  echo "Approve FastShot under Screen & System Audio Recording once. Future builds keep the permission."
else
  open "$DEST"
  echo "Installed $DEST"
fi
