# App-Icon

`AppIcon-1024.png` ist das Marketing-Icon für App Store und Xcode: 1024 × 1024 px, randlos und ohne Alpha. Die Rundung legt iOS selbst darüber. Es entsteht aus denselben SVG-Bausteinen wie die PWA-Icons in `scripts/generate-icons.js` des Server-Repos, also aus Verlauf, Glanz und den drei Kreisen in der Safe-Zone.

Neu erzeugen, aus einem Server-Worktree mit `npm ci`:

    node design/app-icon/make-icon.mjs <server-worktree> design/app-icon/AppIcon-1024.png
