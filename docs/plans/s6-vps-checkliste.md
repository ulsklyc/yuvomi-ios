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

## Was Claude dann einrichtet

- Docker und das offizielle Image `ghcr.io/ulsklyc/yuvomi`, auf eine Version gepinnt.
- HTTPS für `review.yuvomi.cloud` über einen Reverse Proxy mit automatischem Zertifikat.
- Nur Seed-Daten aus `scripts/seed-demo.js`, ein Konto ohne 2FA für die Review.
- Ein Update-Skript, das das Image auf eine neue Version zieht und neu startet.
- Link und Zugangsdaten stehen nirgends öffentlich (`SCOPE.md:344-356`). Sie gehen nur in die Review-Notes bei Apple.
