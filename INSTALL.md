# Installation von Usage Bar (Anleitung für Claude Code)

Diese Datei ist für den KI-Assistenten geschrieben, der Usage Bar für jemanden installiert. Arbeite die Schritte der Reihe nach ab und erledige alles selbst. Die Person muss nur zwei Dinge selbst tun: eine Systemabfrage bestätigen, falls Werkzeuge fehlen, und sich am Ende bei claude.ai anmelden. Antworte in der Sprache, in der du angesprochen wurdest, kurz und ohne Fachchinesisch.

Usage Bar ist eine kleine Menüleisten-App für macOS. Sie zeigt, wie viel vom 5-Stunden-Limit und vom Wochenlimit des Claude-Plans verbraucht ist. Sie braucht keinen API-Key und keine Tokens. Gib niemals ein Passwort ein und melde die Person nicht selbst an.

## 1. Voraussetzungen prüfen

```bash
sw_vers -productVersion
xcode-select -p
```

- macOS muss Version 15 oder neuer sein. Ist es älter, abbrechen und sagen, dass Usage Bar macOS 15 (Sequoia) braucht.
- Gibt `xcode-select -p` einen Fehler aus, fehlen die Xcode Command Line Tools (darin stecken `git` und `swift`). Dann:
  1. `xcode-select --install` ausführen. Es öffnet sich ein Systemfenster.
  2. Der Person sagen: „Es ist ein Fenster aufgegangen. Klick dort auf „Installieren“ und stimm den Bedingungen zu. Das dauert ein paar Minuten, ich warte so lange.“
  3. Warten, bis `xcode-select -p` ohne Fehler durchläuft. Prüf alle 30 Sekunden, höchstens 30 Minuten lang. Nicht weitermachen, bevor das klappt.

## 2. Quellcode holen oder aktualisieren

```bash
SRC="$HOME/Library/Application Support/UsageBar/source"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --quiet origin && git -C "$SRC" reset --hard --quiet origin/main
else
  mkdir -p "$(dirname "$SRC")" && git clone --quiet https://github.com/heyfreiheit/usage-bar.git "$SRC"
fi
```

Der Ordner gehört nur Usage Bar, lokale Änderungen darin dürfen überschrieben werden.

## 3. Bauen und installieren

```bash
zsh "$HOME/Library/Application Support/UsageBar/source/scripts/install.sh"
```

Das Skript baut die App (beim ersten Mal 1 bis 2 Minuten), legt sie nach `~/Applications/Usage Bar.app`, beendet eine laufende ältere Version und startet die neue. Erfolgreich ist es, wenn die letzte Zeile `[usage-bar] FERTIG` lautet.

Wenn das Skript abbricht, steht der Grund in der Zeile mit `FEHLER`:

| Exit-Code | Bedeutung | Was tun |
|---|---|---|
| 2 | macOS zu alt | abbrechen, Person informieren |
| 3 | Command Line Tools fehlen | zurück zu Schritt 1 |
| 4 | Swift älter als 6 | `softwareupdate --list` ausführen, das Paket „Command Line Tools for Xcode“ mit `softwareupdate --install "<Name>"` installieren (braucht eventuell das Admin-Passwort, das tippt die Person selbst ein), dann Schritt 3 wiederholen |
| 5 | Build fehlgeschlagen | Ausgabe lesen. Häufigste Ursache sind veraltete Command Line Tools, dann wie bei 4. Sonst einmal `rm -rf ~/Library/Caches/usage-bar-build` und Schritt 3 wiederholen |

Fragt deine Umgebung nach einer Freigabe, weil das Skript außerhalb des aktuellen Ordners schreibt (`~/Applications`, `~/Library/Caches`), bitte die Person, sie zu erteilen.

## 4. Anmelden lassen

Nach dem Start steht oben rechts in der Menüleiste „Login“, und es öffnet sich ein Fenster „Bei claude.ai anmelden“. Sag der Person:

> Usage Bar ist installiert. Es ist ein Fenster „Bei claude.ai anmelden“ aufgegangen. Melde dich dort mit deinem Claude-Konto an, so wie sonst auch (Google, Apple oder E-Mail). Danach geht das Fenster von selbst zu, und oben in der Menüleiste stehen deine Limits, zum Beispiel „5h 12 %  W 30 %“. Sag mir Bescheid, wenn du fertig bist.

Falls das Fenster nicht zu sehen ist: In der Menüleiste auf „Login“ klicken, dann auf „Bei claude.ai anmelden“.

## 5. Prüfen

Wenn die Person sagt, dass sie angemeldet ist:

```bash
ls -la "$HOME/Library/Application Support/UsageBar/last-usage.json"
```

Die Datei muss existieren und wenige Minuten alt sein. Dann kurz erklären:

- „5h“ ist das 5-Stunden-Limit der aktuellen Session, „W“ das Wochenlimit.
- Ein Klick auf die Anzeige zeigt die Details, wann die Limits zurückgesetzt werden und ob oben „verbraucht“ oder „noch frei“ stehen soll.
- Der feine Strich im Balken zeigt, wie weit das Zeitfenster schon gelaufen ist. Liegt der Balken rechts davon, wird gerade schneller verbraucht, als die Zeit vergeht.
- Die App startet automatisch mit dem Mac. Abschalten geht im Menü.

Fehlt die Datei nach ein paar Minuten, die App neu starten (`pkill -x UsageBar; open "$HOME/Applications/Usage Bar.app"`) und die Person bitten, das Menü einmal zu öffnen. Die Fehlermeldung im Menü sagt dann, was los ist.

## Aktualisieren

Dieselben Schritte 2 und 3 noch einmal ausführen. Der Login bleibt erhalten.

## Deinstallieren

```bash
pkill -x UsageBar
rm -rf "$HOME/Applications/Usage Bar.app" "$HOME/Library/Application Support/UsageBar" "$HOME/Library/Caches/usage-bar-build"
rm -rf "$HOME/Library/WebKit/com.heyfreiheit.usagebar" "$HOME/Library/HTTPStorages/com.heyfreiheit.usagebar"*
defaults delete com.heyfreiheit.usagebar 2>/dev/null
```

Den Eintrag unter Systemeinstellungen > Allgemein > Anmeldeobjekte entfernt macOS von selbst, sobald die App weg ist.
