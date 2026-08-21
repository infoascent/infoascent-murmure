# Murmur — fork InfoAscent

Fork de [per-simmons/murmur-youtube](https://github.com/per-simmons/murmur-youtube),
adapté au français et corrigé pour fonctionner en usage réel sur macOS 26.

## Installation

```bash
make signing-cert   # une seule fois par machine
make install
```

Puis accorder **Accessibilité** et **Micro** dans Réglages Système, et libérer la touche
push-to-talk si macOS se l'est réservée (Réglages Système ▸ Clavier ▸ « Appuyer sur 🌐 pour »
= Ne rien faire).

## Ce qui a été corrigé par rapport à l'amont

### Blocages qui empêchaient toute dictée

1. **Signature ad-hoc.** TCC lie l'autorisation Accessibilité à l'identité de signature, et
   une signature ad-hoc est régénérée à chaque build. Chaque `make install` révoquait donc
   silencieusement l'autorisation : la case restait cochée, la base TCC disait « autorisé »,
   et `CGEventTapCreate` échouait quand même. Le Makefile signe maintenant avec un
   certificat local stable (`make signing-cert`).

2. **Mixage multicanal.** `AVAudioEngine` met son format de sortie d'entrée en cache et ne le
   rafraîchit jamais après un changement de périphérique : `setDeviceID` déplace bien le
   matériel (`inputFormat` passe à 1 canal) mais `outputFormat` reste sur le périphérique
   précédent, et le nœud ré-étale le micro mono sur tous ses canaux. `AVAudioConverter` en
   faisait ensuite la moyenne — un agrégat 16 canaux divisait la voix par 16, soit ~24 dB
   sous le seuil de reconnaissance. Assez fort pour bouger un VU-mètre, inaudible pour le
   moteur, et signalé nulle part. `AudioCapture` sélectionne désormais le canal porteur.

3. **Aucun sélecteur de micro.** L'amont utilisait le périphérique d'entrée par défaut du
   système, qui est fréquemment un agrégat installé par un enregistreur d'écran. Ajout de
   `AudioDevices.swift` et d'un sélecteur dans la fenêtre, les réglages et le menu.

4. **Logs illisibles.** OSLog masque les chaînes dynamiques par défaut, donc chaque
   diagnostic s'affichait `<private>`. Les messages de diagnostic sont marqués `.public`.

### Français

- Prompt de nettoyage bilingue avec interdiction stricte de traduire.
- Mots parasites français (euh, genre, du coup, en fait, voilà, bref…).
- Garde-fou anti-hallucination replié sur les accents, et fragments d'élision (`j`, `l`,
  `c`, `n`, `qu`) ajoutés aux mots-outils — sans quoi « je ai » → « j'ai » était compté
  comme un mot inventé et faisait rejeter tout le nettoyage.
- Ponctuation dictée en français (« à la ligne », « nouveau paragraphe »…).

### Performance du nettoyage

- Préchauffage du modèle au lancement : le premier appel à Foundation Models bloque assez
  longtemps pour affamer le pool de tâches, au point qu'un budget de 4 s était servi à 9 s.
- Découpage par phrases (~400 caractères) : la latence du modèle croît avec la longueur, et
  un délai global jetait le nettoyage de toutes les phrases parce que la dernière était
  lente.

### Interface

Design « vieille radio » remplacé par du natif macOS. Les contrôles dessinés à la main
enveloppaient un `Button` dans un `onLongPressGesture` qui avalait le clic — le bouton
Save du dictionnaire ne partait jamais, donc rien ne pouvait y être ajouté.

- Onglets au lieu d'une barre latérale (qui se repliait et masquait toute la navigation).
- HUD réduit à une pilule de 62 × 26 pt, positionnée sous le curseur texte via l'API
  d'accessibilité (`CaretLocator.swift`), avec repli sur la position de la souris.
- Fermer la fenêtre ne quitte plus l'app : elle reste dans la barre de menus et l'icône du
  Dock disparaît, par bascule de la politique d'activation plutôt que via `LSUIElement`
  (qui aurait aussi supprimé la barre de menus de l'app).
