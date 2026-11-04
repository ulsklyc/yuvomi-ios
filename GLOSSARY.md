# Yuvomi für iOS

Der native Client für einen selbst gehosteten Yuvomi-Server. Er spricht nur mit dem Server des eigenen Haushalts.

## Anmeldung

**Signed-in device**:
Ein Telefon mit der App, das mit dem Konto einer Person angemeldet ist. In der Oberfläche „Angemeldetes Gerät“, die Liste heißt „Angemeldete Geräte“.
_Avoid_: gekoppeltes Gerät, Client

**Device credential**:
Der Schlüssel, mit dem ein signed-in device beim Server auftritt. Eine Person kann ihn je Gerät widerrufen.
_Avoid_: device token (meint bei Apple das APNs-Token), API-Token

**Kopplungscode**:
Ein kurzer, einmal gültiger Code aus der Web-App, gegen den die App ein device credential bekommt, ohne Passwort. Er erreicht die App als QR-Code, als App-Link oder abgetippt.
_Avoid_: Pairing-Token, PIN

**App-Link**:
Der Link `yuvomi://pair` mit Server-Adresse und Kopplungscode. Hinter „In der App öffnen“ und im QR-Code steht derselbe App-Link.
_Avoid_: Deep Link, Universal Link

## Erinnerungen

**Erinnerung**:
Ein Zeitpunkt, zu dem der Server eine Person an eine Aufgabe oder einen Termin erinnern will. Sie gehört dem Server und einer Person, die App bekommt nur einen Abzug der kommenden.
_Avoid_: Reminder, Alarm, Wecker

**Mitteilung**:
Was iOS zum Zeitpunkt einer Erinnerung auf dem Telefon zeigt. Die App plant sie auf dem Gerät, ohne dass der Server sie schickt.
_Avoid_: Push, Notification, Benachrichtigung

**Verwerfen**:
Eine Erinnerung als gesehen markieren. Danach erinnert der Server auf keinem Weg mehr daran, weder in der Glocke der Web-App noch per Web-Push noch in der App. Die Aufgabe oder der Termin bleibt dabei unverändert.
_Avoid_: dismiss, als gelesen markieren, löschen

**Abhaken**:
Eine Aufgabe als erledigt markieren. Einen Termin hakt man nicht ab, an ihm lässt sich nur die Erinnerung verwerfen.
_Avoid_: check (meint am Server eine Zeile der Checkliste), done

**Rückmeldung**:
Was eine Person an einer Mitteilung tut und die App an den Server weitergibt: Verwerfen der Erinnerung oder Abhaken der Aufgabe. Bis der Server sie angenommen hat, merkt die App sich die Rückmeldung.
_Avoid_: Antwort, Response, Aktion (meint bei Apple den Knopf)

**Abgleich**:
Die App holt die kommenden Erinnerungen und bringt die geplanten Mitteilungen auf diesen Stand: neue dazu, weggefallene weg, geänderte neu.
_Avoid_: Sync, Refresh
