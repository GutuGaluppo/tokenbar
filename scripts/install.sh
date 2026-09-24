#!/bin/zsh
# Compila o TokenBar em Release e instala em /Applications (uso pessoal, sem notarização).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Compilando (Release)…"
xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Release \
  -derivedDataPath build/DerivedData -quiet build

echo "Instalando em /Applications…"
pkill -x TokenBar 2>/dev/null || true
sleep 1
rm -rf /Applications/TokenBar.app
ditto build/DerivedData/Build/Products/Release/TokenBar.app /Applications/TokenBar.app

# Evita dois widgets "TokenBar" na galeria: desregistra o do build de desenvolvimento.
pluginkit -r build/DerivedData/Build/Products/Debug/TokenBar.app/Contents/PlugIns/TokenBarWidget.appex 2>/dev/null || true

open /Applications/TokenBar.app
echo "Pronto. Se usava \"Abrir ao iniciar sessão\", desligue e ligue de novo em Ajustes para apontar para /Applications."
