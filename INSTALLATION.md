# Installer InfoAscent Murmure

Dictée vocale pour Mac : tu maintiens une touche, tu parles, tu relâches, le texte s'écrit
tout seul là où se trouve ton curseur. Tout tourne sur ta machine, rien ne part sur Internet,
il n'y a aucun compte à créer et aucun abonnement.

Aucune connaissance en informatique n'est nécessaire. Deux options ci-dessous : demander à
Claude Code de le faire, ou copier une seule commande.

---

## Ce qu'il faut avoir

| | |
|---|---|
| **Un Mac sous macOS 26 (Tahoe) ou plus récent** | Obligatoire. La reconnaissance vocale utilisée ici n'existe pas avant. Menu Pomme ▸ Réglages Système ▸ Général ▸ Mise à jour. |
| 3 Go d'espace libre | Pour les outils de compilation d'Apple, installés automatiquement si besoin. |
| 15 minutes | Dont 3 à 10 minutes de compilation où tu n'as rien à faire. |

Pas besoin d'Xcode complet, ni de compte développeur Apple, ni de carte bancaire.

---

## Option A : tu as Claude Code

Colle ceci dans Claude Code :

> Installe InfoAscent Murmure depuis https://github.com/infoascent/infoascent-murmure
> en suivant la section « Procédure pour un agent » de son fichier INSTALLATION.md.

## Option B : une seule commande

Ouvre l'app **Terminal** (Cmd + Espace, tape « Terminal », Entrée), colle la ligne
suivante, appuie sur Entrée, et suis ce qui s'affiche :

```bash
cd ~ && git clone https://github.com/infoascent/infoascent-murmure.git && cd infoascent-murmure && bash install.sh
```

Le script vérifie ta machine, installe ce qui manque, compile l'app, l'installe dans le
dossier Applications, et t'ouvre le réglage à cocher. Il ne demande jamais ton mot de passe.

---

## Les deux autorisations à accorder

macOS interdit à un script d'accorder ces deux autorisations : il faut un clic humain.
C'est une protection du système, pas un problème d'installation.

1. **Accessibilité** (indispensable) : Réglages Système ▸ Confidentialité et sécurité ▸
   Accessibilité, puis active **InfoAscent Murmure**. Si l'app n'est pas dans la liste,
   clique « + » et va la chercher dans le dossier Applications.
   Ensuite **quitte complètement Réglages Système avec Cmd + Q** (ce panneau garde une
   liste en cache et ment tant qu'il n'a pas été relancé), puis relance l'app.
2. **Micro** : la demande arrive d'elle-même à ta première dictée. Réponds « Autoriser ».

---

## Comment on dicte

Maintiens la touche **Option de droite** (⌥, juste à droite de la barre d'espace), parle,
relâche.

- Appui de moins de 0,4 seconde : ignoré volontairement, pour ne pas déclencher une dictée
  quand ta main effleure la touche en tapant.
- **Double-tap** : le micro reste ouvert sans que tu tiennes la touche. Un tap pour finir.
- L'app vit dans la **barre de menus** en haut à droite de l'écran, sans icône dans le Dock.
  C'est là que tu changes la touche, le micro utilisé et la langue.

---

## Si ça ne marche pas

| Symptôme | Cause et solution |
|---|---|
| La touche ne fait rien, alors que la case Accessibilité est cochée | La case coche une ligne périmée. Ouvre le Terminal : `tccutil reset Accessibility com.infoascent.murmure`, quitte Réglages Système avec Cmd + Q, rouvre le panneau, re-coche, relance l'app. |
| « input file was modified during the build » | Le dossier du projet est synchronisé avec iCloud. Déplace-le dans ton dossier personnel (`~/infoascent-murmure`) et relance `bash install.sh`. |
| L'app entend mais n'écrit rien, ou le texte part au mauvais endroit | L'autorisation Accessibilité manque : c'est elle qui sert à écrire le texte, pas seulement à lire la touche. |
| Le VU-mètre bouge mais aucun texte n'apparaît | Mauvais micro sélectionné (souvent un périphérique agrégé installé par un enregistreur d'écran). Choisis ton vrai micro dans le menu de la barre de menus. |
| Tu veux utiliser la touche 🌐 / fn | macOS se la réserve pour les emoji. Réglages Système ▸ Clavier ▸ « Appuyer sur 🌐 pour » = **Ne rien faire**, puis choisis fn dans le menu de l'app. |
| macOS refuse d'ouvrir l'app (développeur non identifié) | Clic droit sur l'app ▸ Ouvrir, puis confirme. L'app est signée localement mais pas notarisée par Apple. |

Mettre à jour plus tard, une fois installée :

```bash
cd ~/infoascent-murmure && git pull && make install
```

---

## Procédure pour un agent

Cette section est destinée à un agent de code (Claude Code) installant l'app pour un
utilisateur qui ne lit pas de code. Suis-la dans l'ordre, sans sauter d'étape.

**Contrat de comportement**

- Fais tout toi-même. Ne rends jamais une liste d'étapes à exécuter à la main.
- Ne demande à l'utilisateur que ce que macOS t'interdit de faire : cocher la case
  Accessibilité, répondre à la demande de micro, et le cas échéant valider la fenêtre
  d'installation des outils Apple. Une demande à la fois, au moment où elle bloque.
- Explique les résultats en langage courant. L'utilisateur ne sait pas ce qu'est TCC,
  une signature de code ou un event tap, et n'a pas besoin de le savoir.

**Étapes**

1. **Vérifie la version de macOS avant toute autre chose** : `sw_vers -productVersion`.
   Le paquet impose `platforms: [.macOS(.v26)]` et le moteur vocal est `SpeechAnalyzer`,
   introduit dans macOS 26. En dessous de 26, **rien ne compile** : dis-le clairement,
   demande une mise à jour de macOS, et arrête-toi là. N'essaie pas de rétroporter, de
   baisser la cible de plateforme ni de substituer un autre moteur.
2. **Clone hors des dossiers synchronisés iCloud** (ni `~/Desktop`, ni `~/Documents`).
   `~/infoascent-murmure` convient. Le fournisseur iCloud modifie les fichiers pendant la
   compilation, ce qui produit des échecs aléatoires et des signatures corrompues.
3. **Lance `bash install.sh`** depuis la racine du projet. Il enchaîne les vérifications,
   l'installation des Command Line Tools si elles manquent, la création du certificat de
   signature local, `make install`, et l'ouverture du panneau Accessibilité. Ne reproduis
   pas ses étapes à la main : c'est lui qui contient les garde-fous.
4. **Ne remplace jamais la signature par de l'ad-hoc** (`--sign -`). macOS lie
   l'autorisation Accessibilité à l'identité de signature, pas au chemin. Une signature
   ad-hoc change à chaque compilation, l'autorisation est donc révoquée en silence à chaque
   mise à jour, et le symptôme mentira : la case restera cochée pendant que
   `CGEventTapCreate` échoue. `make signing-cert` crée un certificat local stable, sans
   compte Apple, et le Makefile le détecte tout seul.
5. **Compile toujours avec `make`, jamais avec `swift build` seul.** Le Makefile place les
   produits de compilation hors du dossier du projet, ce qui évite à la fois le conflit
   iCloud et un `.app` non signable.
6. **Accorde-toi le droit d'attendre.** La première compilation prend 3 à 10 minutes, et
   au premier usage macOS peut télécharger un modèle de langue. Ce n'est pas un blocage.
7. **Fais vérifier la dictée par l'utilisateur** : demande-lui d'ouvrir une note, de
   maintenir l'Option de droite, de dire une phrase et de relâcher. C'est la seule étape
   qu'aucun script ne peut valider, parce qu'elle exige une voix réelle et une fenêtre au
   premier plan.
8. **En cas de panne**, commence par le tableau « Si ça ne marche pas » ci-dessus, puis lis
   `AGENTS.md` : il recense les comportements qui ressemblent à des bugs et n'en sont pas
   (mode comparaison qui n'écrit rien volontairement, format audio mis en cache par
   `AVAudioEngine`, `finalizeAndFinishThroughEndOfInput()` qui ne revient jamais sur une
   dictée quasi vide). Ne corrige rien sans avoir identifié la cause : ces trois pannes
   ont chacune coûté une session entière de diagnostic parce qu'aucune ne produit d'erreur
   visible.
9. **Diagnostic** : les journaux de l'app se lisent avec
   `/usr/bin/log show --predicate 'subsystem == "com.infoascent.murmure"' --last 10m`.
   Utilise le chemin complet : `log` est souvent masqué par une autre commande dans le shell.
