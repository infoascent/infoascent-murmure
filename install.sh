#!/bin/bash
#
# InfoAscent Murmure : installation automatique sur macOS.
#
#   bash install.sh
#
# Le script vérifie la machine, compile l'app, la signe avec un certificat local stable,
# l'installe dans /Applications et ouvre les deux panneaux d'autorisation à accorder.
# Il ne touche à rien d'autre sur la machine et ne demande jamais de mot de passe.

set -u

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'

etape()  { printf '\n%s▸ %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()     { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
attn()   { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$1"; }
stop()   { printf '\n%s✗ %s%s\n\n%s\n\n' "$RED" "$1" "$OFF" "${2:-}"; exit 1; }

cd "$(dirname "$0")" || stop "Impossible d'entrer dans le dossier du projet."
RACINE="$(pwd)"

printf '\n%sInfoAscent Murmure : installation%s\n%sDictée vocale locale pour macOS. Rien ne sort de la machine.%s\n' \
  "$BOLD" "$OFF" "$DIM" "$OFF"

# ─────────────────────────────────────────────────────────────────────────────
etape "1/6  Vérification de la machine"

[ "$(uname -s)" = "Darwin" ] || stop "Cette app est une app macOS." \
  "Elle ne fonctionne ni sur Windows ni sur Linux."

VERSION_MACOS="$(sw_vers -productVersion)"
MAJEUR="${VERSION_MACOS%%.*}"
if [ "$MAJEUR" -lt 26 ]; then
  stop "macOS $VERSION_MACOS est trop ancien : il faut macOS 26 (Tahoe) ou plus récent." \
"La reconnaissance vocale utilisée ici (SpeechAnalyzer d'Apple) n'existe qu'à partir de
macOS 26. Sans elle, l'app ne peut pas être compilée du tout.

  → Mets macOS à jour : menu Pomme ▸ Réglages Système ▸ Général ▸ Mise à jour,
    puis relance : bash install.sh"
fi
ok "macOS $VERSION_MACOS"

case "$(uname -m)" in
  arm64) ok "Mac Apple Silicon" ;;
  *)     attn "Mac Intel : la dictée fonctionne, mais sera plus lente." ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
etape "2/6  Outils de compilation"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  attn "Les outils de développement Apple sont absents. Installation en cours…"
  printf '    %sUne fenêtre macOS va s'\''ouvrir : clique « Installer » et accepte.%s\n' "$DIM" "$OFF"
  xcode-select --install 2>/dev/null
  printf '\n  Attente de la fin de l'\''installation (plusieurs minutes, ne ferme pas ce terminal)'
  for _ in $(seq 1 240); do
    command -v swift >/dev/null 2>&1 && break
    printf '.'; sleep 15
  done
  printf '\n'
  command -v swift >/dev/null 2>&1 || stop "Les outils de développement ne sont toujours pas là." \
"Termine l'installation lancée par macOS (ou installe Xcode depuis l'App Store),
puis relance : bash install.sh"
fi

SWIFT_VERSION="$(swift --version 2>/dev/null | grep -o 'Swift version [0-9.]*' | head -1 | awk '{print $3}')"
SWIFT_MAJEUR="${SWIFT_VERSION%%.*}"
SWIFT_MINEUR="$(printf '%s' "$SWIFT_VERSION" | cut -d. -f2)"
if [ -z "$SWIFT_VERSION" ] || [ "${SWIFT_MAJEUR:-0}" -lt 6 ] \
   || { [ "$SWIFT_MAJEUR" -eq 6 ] && [ "${SWIFT_MINEUR:-0}" -lt 2 ]; }; then
  stop "Swift ${SWIFT_VERSION:-introuvable} est trop ancien : il faut Swift 6.2 ou plus." \
"Mets à jour les outils de développement :

  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install

puis relance : bash install.sh"
fi
ok "Swift $SWIFT_VERSION"

command -v make >/dev/null 2>&1 || stop "L'outil « make » est introuvable." \
"Lance : xcode-select --install"
ok "make présent"

# ─────────────────────────────────────────────────────────────────────────────
etape "3/6  Emplacement du dossier"

# iCloud « Bureau et Documents » remplace et rematérialise les fichiers pendant la
# compilation : le compilateur lit alors un fichier modifié sous ses pieds et échoue,
# ou signe un binaire corrompu. Rien à réparer, il suffit de compiler ailleurs.
case "$RACINE" in
  "$HOME/Desktop"/*|"$HOME/Documents"/*|"$HOME/Library/Mobile Documents"/*)
    attn "Ce dossier est peut-être synchronisé avec iCloud, ce qui fait échouer la compilation."
    DEST="$HOME/infoascent-murmure"
    printf '    Je déplace le projet vers %s\n' "$DEST"
    if [ -e "$DEST" ]; then
      attn "$DEST existe déjà, je garde ce dossier-là et je continue dedans."
    else
      mv "$RACINE" "$DEST" || stop "Le déplacement a échoué." "Déplace le dossier hors de Bureau/Documents à la main, puis relance : bash install.sh"
    fi
    cd "$DEST" || stop "Impossible d'entrer dans $DEST"
    RACINE="$DEST"
    ok "Projet déplacé, compilation depuis $RACINE"
    ;;
  *) ok "Emplacement correct ($RACINE)" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
etape "4/6  Certificat de signature local"

# macOS lie l'autorisation « Accessibilité » à la signature de l'app, pas à son chemin.
# Une signature ad-hoc change à chaque compilation : l'autorisation serait révoquée en
# silence à chaque mise à jour, la case resterait cochée, et la touche ne ferait plus rien.
if security find-identity -v -p codesigning 2>/dev/null \
     | grep -qE 'Developer ID Application|Murmur Local Signing'; then
  ok "Certificat déjà présent"
else
  printf '  Création du certificat (local, valable 10 ans, aucun compte Apple requis)…\n'
  make signing-cert >/dev/null 2>&1
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Murmur Local Signing"; then
    ok "Certificat créé"
  else
    stop "La création du certificat a échoué." \
"Relance la commande seule pour voir l'erreur :

  make signing-cert"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
etape "5/6  Compilation et installation"
printf '  Première compilation : 3 à 10 minutes selon le Mac. C'\''est normal.\n\n'

if ! make install; then
  printf '\n'
  stop "La compilation a échoué." \
"Relance « make install » et donne la sortie complète à Claude Code : le message
d'erreur au-dessus dit précisément ce qui manque.

Si l'erreur parle de « input file was modified during the build », c'est la
synchronisation iCloud : déplace le dossier dans $HOME et relance."
fi

[ -d "/Applications/InfoAscent Murmure.app" ] || stop "L'app n'est pas arrivée dans /Applications." \
"Relance : make install"
ok "Installée dans /Applications/InfoAscent Murmure.app"

# ─────────────────────────────────────────────────────────────────────────────
etape "6/6  Les deux autorisations à accorder"

# Ces deux réglages ne peuvent pas être accordés par un script : macOS exige un clic
# humain dans Réglages Système. C'est une protection du système, pas un bug.
cat <<'TXT'
  macOS exige que tu accordes deux autorisations à la main. Un script n'a pas le droit
  de le faire, c'est une protection du système.

  1. ACCESSIBILITÉ  (indispensable : c'est ce qui permet de voir la touche et d'écrire le texte)
     Le panneau va s'ouvrir. Active « InfoAscent Murmure » dans la liste.
     Si l'app n'apparaît pas : bouton « + », puis choisis-la dans le dossier Applications.

  2. MICRO
     Demandé automatiquement à ta première dictée : réponds « Autoriser ».

TXT
printf '  %sAppuie sur Entrée pour ouvrir le panneau Accessibilité…%s ' "$DIM" "$OFF"
read -r _ </dev/tty 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cat <<'TXT'

  Une fois la case cochée, quitte complètement Réglages Système (Cmd + Q), puis relance
  l'app depuis le dossier Applications.

TXT

# ─────────────────────────────────────────────────────────────────────────────
cat <<'TXT'
─────────────────────────────────────────────────────────────────────────
  COMMENT ON DICTE

  Maintiens la touche Option de DROITE (⌥, à droite de la barre d'espace),
  parle, relâche. Le texte s'écrit tout seul là où se trouve ton curseur.

  • Appui trop court (moins de 0,4 s) : ignoré volontairement.
  • Double-tap : garde le micro ouvert sans tenir la touche. Un tap pour finir.
  • L'app vit dans la barre de menus en haut à droite (pas d'icône dans le Dock).
    Tu y changes la touche, le micro, et la langue.

  Tout se passe sur ta machine : aucun audio, aucun texte n'est envoyé sur Internet.

  Mettre à jour plus tard :   cd DOSSIER && git pull && make install
─────────────────────────────────────────────────────────────────────────
TXT
printf '%s✓ Installation terminée.%s\n\n' "$GREEN" "$OFF"
