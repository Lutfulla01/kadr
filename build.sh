#!/bin/zsh
# Kadr: сборка (arm64 + x86_64) → Kadr.app → подпись → установка в /Applications → перезапуск.
#   ./build.sh         — собрать, установить в /Applications, перезапустить
#   ./build.sh app     — только собрать build/Kadr.app (ничего не устанавливает и не перезапускает)
#   ./build.sh dmg     — собрать и упаковать dist/Kadr-<версия>.dmg (без установки)
#                        KADR_DMG_LAYOUT=1 — ещё и разложить окно образа через Finder (откроет окно Finder на экране)
#
# Подпись: KADR_SIGN_IDENTITY=<имя или SHA-1 сертификата> или файл .signing (одна строка, в git не попадает).
# Без них — подпись ad-hoc ("-"): работает, но macOS после каждой пересборки заново спросит
# «Запись экрана» и «Универсальный доступ».
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-install}"
IDENTITY="${KADR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing ]]; then IDENTITY=$(head -n 1 .signing | tr -d '[:space:]'); fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"
APP="build/Kadr.app"
DEST="/Applications/Kadr.app"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

mkdir -p build Resources
if [[ ! -f Resources/Kadr.icns || tools/make_icon.swift -nt Resources/Kadr.icns ]]; then
  echo "→ иконка"
  swiftc -O tools/make_icon.swift -o build/make_icon
  build/make_icon Resources/Kadr.icns
fi

echo "→ компиляция (arm64 + x86_64)"
pids=()
rm -f build/Kadr-arm64 build/Kadr-x86_64
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos14.0" \
    -file-prefix-map "$PWD=." \
    -framework AppKit -framework SwiftUI -framework Vision -framework CoreImage \
    -framework Carbon -framework ServiceManagement -framework Security -framework CryptoKit \
    Sources/*.swift -o "build/Kadr-$arch" &
  pids+=($!)
done
for pid in $pids; do wait $pid || { echo "ОШИБКА компиляции"; exit 1; }; done
lipo -create build/Kadr-arm64 build/Kadr-x86_64 -output build/Kadr
lipo -info build/Kadr

echo "→ сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Kadr "$APP/Contents/MacOS/Kadr"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Kadr.icns "$APP/Contents/Resources/Kadr.icns"
# Русская локализация: системные строки (размеры файлов, панели сохранения, «Поделиться») — по-русски.
mkdir -p "$APP/Contents/Resources/ru.lproj"
printf '"CFBundleDisplayName" = "Kadr";\n' > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$IDENTITY" == "-" ]]; then
  echo "→ подпись ad-hoc (hardened runtime)"
else
  echo "→ подпись сертификатом из KADR_SIGN_IDENTITY / .signing (hardened runtime)"
fi
codesign --force --deep --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

adhoc_note() {
  if [[ "$IDENTITY" == "-" ]]; then
    echo ""
    echo "Внимание: подпись ad-hoc. После каждой пересборки macOS считает Kadr новой программой"
    echo "и снова спросит «Запись экрана» и «Универсальный доступ» (старые строки в Настройках можно удалить)."
    echo "Чтобы разрешения сохранялись, подписывайте своим сертификатом: KADR_SIGN_IDENTITY=... или файл .signing."
  fi
}

if [[ "$MODE" == "build" || "$MODE" == "app" ]]; then echo "готово: $APP"; adhoc_note; exit 0; fi

if [[ "$MODE" == "dmg" ]]; then
  echo "→ образ диска"
  STAGE="build/dmg-stage"
  RW="build/Kadr-rw.dmg"
  OUT="dist/Kadr-$VER.dmg"
  rm -rf "$STAGE" "$RW"
  mkdir -p "$STAGE/.background" dist
  ditto "$APP" "$STAGE/Kadr.app"
  ln -s /Applications "$STAGE/Applications"
  cp "Resources/dmg/Как открыть.txt" "$STAGE/"
  if [[ ! -x build/make_dmg_bg || tools/make_dmg_bg.swift -nt build/make_dmg_bg ]]; then
    swiftc -O tools/make_dmg_bg.swift -o build/make_dmg_bg
  fi
  build/make_dmg_bg build/dmg-bg.png build/dmg-bg@2x.png
  tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null
  cp Resources/Kadr.icns "$STAGE/.VolumeIcon.icns"

  hdiutil create -quiet -srcfolder "$STAGE" -volname "Kadr" -fs HFS+ -format UDRW -size 60m -ov "$RW"
  BROWSE=(-nobrowse)
  [[ "${KADR_DMG_LAYOUT:-0}" == "1" ]] && BROWSE=()
  DEV_LINE=$(hdiutil attach -readwrite -noverify -noautoopen "${BROWSE[@]}" "$RW" | grep '/Volumes/' | tail -1)
  DEV=$(echo "$DEV_LINE" | awk '{print $1}')
  MNT=$(echo "$DEV_LINE" | sed -E 's|.*(/Volumes/.*)$|\1|')
  SetFile -a C "$MNT" || true
  SetFile -a V "$MNT/.VolumeIcon.icns" "$MNT/.background" 2>/dev/null || true
  if [[ "${KADR_DMG_LAYOUT:-0}" == "1" ]]; then
    echo "→ раскладка окна через Finder"
    VOLNAME=$(basename "$MNT")
    if ! perl -e 'alarm shift; exec @ARGV' 40 osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 562}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Kadr.app" of container window to {170, 220}
    set position of item "Applications" of container window to {470, 220}
    set position of item "Как открыть.txt" of container window to {320, 360}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
    then echo "  раскладка не удалась — образ будет без фона (работает и так)"; fi
  fi
  sync
  hdiutil detach -quiet "$DEV" || hdiutil detach -force -quiet "$DEV"
  rm -f "$OUT"
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
  rm -f "$RW"
  hdiutil verify -quiet "$OUT" && echo "проверка образа: ок"
  ls -lh "$OUT" | awk '{print "готово: " $NF " (" $5 ")"}'
  adhoc_note
  exit 0
fi

echo "→ установка в $DEST"
# Закрываем только настоящий Kadr (без KADR_PROFILE); тестовые профили не трогаем.
if pgrep -x Kadr >/dev/null; then
  for pid in $(pgrep -x Kadr); do
    if ! ps eww -p "$pid" 2>/dev/null | grep -q "KADR_PROFILE="; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for _ in {1..25}; do
    left=0
    for pid in $(pgrep -x Kadr); do ps eww -p "$pid" | grep -q "KADR_PROFILE=" || left=1; done
    [[ $left == 0 ]] && break
    sleep 0.2
  done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "→ запуск"
open "$DEST"
echo "готово: $DEST"
adhoc_note
