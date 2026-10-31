# Orange Business-tema

Tema för rapporterna med Orange-färger (`#ff7900`, svart, vitt) och Helvetica Neue/Arial.

**Logga:** temat använder en textlogga ("Orange" + "Business") som platshållare. Orange-loggan är ett skyddat varumärke och följer inte med i repot. Lägg in den officiella loggan så här, med filer som du har rätt att använda (hämta från Oranges varumärkesportal):

1. Kopiera logofilen (PNG/SVG, högst 300 KB) till den här mappen, till exempel `logo.svg`.
2. Ändra `logo` i `theme.json` till `{ "type": "image", "file": "logo.svg", "alt": "Orange Business" }`.
3. Kontrollera resultatet: `.\Run-Rapportkit.ps1 -ReportOnly -Brand orange -TenantId <tenant>`.

Färgerna är en rimlig utgångspunkt, inte en godkänd profil. Låt varumärkesansvarig granska innan rapporter går till kund.
