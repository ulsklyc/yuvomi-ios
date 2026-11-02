# S6: Checkliste für den Review-VPS

Stand 02.11.2026. Bestellen, bezahlen und den DNS-Eintrag setzen machst du. Die Einrichtung auf dem Server übernimmt danach Claude über SSH.

## Bestellen bei IONOS

- [ ] **Tarif:** der kleinste Linux-VPS. Yuvomi braucht laut `docs/installation.md` 256 MB RAM und rund 500 MB für das Image. 1 GB RAM und 10 GB SSD reichen mit Reserve für Updates und Backups.
- [ ] **Rechenzentrum:** Deutschland.
- [ ] **Betriebssystem:** Debian 13 oder Ubuntu 24.04 LTS, ohne Plesk oder andere Panels.
- [ ] **Zugang:** nur per SSH-Schlüssel. Hinterlege beim Bestellen deinen öffentlichen Schlüssel (`~/.ssh/id_ed25519.pub`). Ein Root-Passwort braucht niemand.
- [ ] **Firewall im IONOS-Panel:** eingehend nur 22 (SSH), 80 (Zertifikat) und 443 (HTTPS).

## DNS

`yuvomi.cloud` liegt auf GitHub Pages. Die Subdomain zeigt getrennt davon auf den VPS.

- [ ] Beim Anbieter, der die DNS-Zone von `yuvomi.cloud` verwaltet: `A`-Eintrag `review` auf die IPv4-Adresse des VPS. Wenn der VPS eine IPv6-Adresse hat, kommt ein `AAAA`-Eintrag dazu.
- [ ] Die Einträge für GitHub Pages (Apex und `www`) bleiben, wie sie sind.

## Danach an Claude

- Die IP-Adresse und den SSH-Benutzer (meist `root`). Ein Passwort gehört nicht in den Chat.
- Ein `ssh <benutzer>@<ip>` muss von diesem Mac aus ohne Passwortabfrage gehen.

## Eingerichtet am 02.11.2026

- **Server:** Debian 13, 1 vCPU, 1,8 GB RAM, Docker 26.1 und Compose 2.26 aus den Debian-Paketen. `review.yuvomi.cloud` zeigt per `A`-Eintrag auf den VPS, einen `AAAA`-Eintrag gibt es nicht.
- **`/opt/yuvomi-review/`:**
  - `compose.yml` mit `ghcr.io/ulsklyc/yuvomi:${YUVOMI_VERSION}`, nur intern erreichbar, davor `caddy:2.10` auf 80 und 443.
  - `Caddyfile` mit Let's-Encrypt-Zertifikat, automatischer Weiterleitung von HTTP auf HTTPS und `X-Robots-Tag: noindex, nofollow`.
  - `.env` mit Rechten 600. `SESSION_SECRET` und `DB_ENCRYPTION_KEY` sind zufällig auf dem Server entstanden, dazu kommen `BASE_URL`, `SESSION_SECURE=true`, `TRUST_PROXY=1` und tägliche Backups, von denen 7 bleiben.
- **Daten:** `scripts/seed-demo.js --locale en` aus `v2.84.0`, gefahren in einem einmaligen Container, das Image bleibt unverändert. Danach haben alle fünf Konten ein zufälliges Passwort statt `demo1234`, keines nutzt 2FA. Die Liste liegt nur auf dem VPS in `/root/review-credentials.txt` (600). Für die Review ist `alex` vorgesehen.
- **Update:** `/opt/yuvomi-review/update.sh 2.85.0` zieht das Image, setzt die Version in `.env`, startet neu, wartet auf `healthy` und zeigt `/api/v1/version`.
- **Geprüft von außen:** HTTPS 200 mit gültigem Zertifikat bis 31.01.2027, `client_api: 1`, `noindex`, HTTP antwortet mit 308 auf HTTPS. Port 3000 ist zu. `demo1234` ergibt 401, das neue Passwort 200.
- **SSH:** nur Schlüssel. `/etc/ssh/sshd_config.d/10-key-only.conf` schaltet Passwort und Keyboard-Interactive ab und erlaubt root nur per Schlüssel. Die Datei steht vor `50-cloud-init.conf`, weil der erste Wert gilt. Geprüft: Eine neue Verbindung mit Schlüssel geht, ein Passwortversuch bekommt `Permission denied (publickey)`.
- **Offen:** Die Firewall im IONOS-Panel ist von hier aus nicht prüfbar.

## Was Claude dann einrichtet

- Docker und das offizielle Image `ghcr.io/ulsklyc/yuvomi`, auf eine Version gepinnt.
- HTTPS für `review.yuvomi.cloud` über einen Reverse Proxy mit automatischem Zertifikat.
- Nur Seed-Daten aus `scripts/seed-demo.js`, ein Konto ohne 2FA für die Review.
- Ein Update-Skript, das das Image auf eine neue Version zieht und neu startet.
- Link und Zugangsdaten stehen nirgends öffentlich (`SCOPE.md:344-356`). Sie gehen nur in die Review-Notes bei Apple.
