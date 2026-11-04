# Branding: utseendet på rapporten

*English: [README.md](README.md)*

Rapportens utseende är **filerna i den här mappen**. Det finns ingen flagga och inget val: byter du filerna blir det ett
nytt utseende.

```
branding\
  theme.json       <- färger, typsnitt, logga, sidfot (Moln på svenska följer med)
  logo.svg         <- valfritt: en logga som bildfil (annars en ordbild av texten i theme.json)
  logo-dark.svg    <- valfritt: logga för mörkt läge
  bakgrund.jpg     <- valfritt: bakgrundsbild
  custom.css       <- valfritt: egna CSS-regler som läggs sist
```

## Så använder du en annan profil

1. Gör en mapp med din profil (kopiera `..\branding-exempel\neutral\theme.json` som utgångspunkt, ändra och lägg till logga).
2. Byt filerna i `branding\` mot den. Rapporten får exakt den profil som ligger i `branding\` när den byggs.

Vill du testa utseendet på en befintlig körning utan att köra verktygen igen: byt filerna i `branding\` och kör
`.\Run-Rapportkit.ps1 -ReportOnly -Period <år-månad>`.

Saknas `theme.json` eller är något ogiltigt faller rapporten tillbaka på inbyggda standardvärden och scriptet skriver en
varning. Det blir aldrig en trasig rapport.

## theme.json

| Fält | Betydelse |
|---|---|
| `name` | Temats namn (visas under "Om körningen") |
| `reportTitle` | Rapportens titel i sidhuvudet |
| `language` | Språk för rapportens text (`en` eller `sv`, ett paket i `..\lang\`). `-ReportLanguage` på scriptet går före. Tomt = engelska |
| `logo` | Se nedan |
| `colors.light`, `colors.dark` | Färgpalett för ljust respektive mörkt läge (följer läsarens inställning). Utskrift använder alltid ljust |
| `colors.status` | Färger för `high`, `medium`, `low` och `ok` (etiketter och kort) |
| `fonts.body`, `fonts.heading` | Typsnittslistor (CSS `font-family`). Typsnitt som inte finns på läsarens dator ersätts av nästa i listan |
| `footer` | Text i sidfoten |
| `contact` | `text` och `url` för en kontaktlänk i sidfoten (lämna tomt för att utelämna) |
| `background` | `file` (bild i mappen, högst 500 KB) och `opacity` (0 till 1, standard 0,08). Visas bakom innehållet, inte vid utskrift |
| `customCss` | Filnamn på en CSS-fil i mappen (valfritt) |

Färger i `colors.*`: `bg`, `surface`, `surfaceAlt`, `border`, `text`, `muted`, `accent` (profilfärg), `accentText`
(profilfärg för text och länkar, måste vara läsbar mot `surface`) och `onAccent` (text ovanpå profilfärgen). Värden
kan vara `#rrggbb`, `rgb(...)`, `hsl(...)` eller ett färgnamn.

### Logga

Antingen en **ordbild** (text i färger), som Moln på svenska:

```json
"logo": { "type": "wordmark", "parts": [ { "text": "Molnpå", "color": "text" }, { "text": "svenska", "color": "accent" } ] }
```

(`color` är `text`, `accent`, `accentText` eller `muted`.) Eller en **bildfil** i mappen (svg, png, jpg, gif eller
webp, högst 300 KB). Den bäddas in i varje sida, så rapporten är fristående:

```json
"logo": { "type": "image", "file": "logo.svg", "fileDark": "logo-dark.svg", "alt": "Företagsnamn", "height": 36 }
```

`fileDark` är valfri: en logga som visas i stället när läsaren använder mörkt läge (till exempel en vit variant).

## Tänk på

- **Rättigheter:** använd bara ett varumärke (namn, logga, färger) som du har rätt att använda. En profil för någon
  annans varumärke, till exempel en kunds eller en arbetsgivares, kräver deras tillstånd. Lägg den inte i det publika repot:
  ha den i en mapp utanför repot.
- **Profil från okänd källa:** `theme.json` valideras (färger och typsnitt kontrolleras, och bara kända färgnamn tillåts i
  loggan), men `custom.css` läggs in som den är. Granska den innan du använder en profil du inte skrivit själv.
- **Typsnitt:** rapporten bäddar inte in typsnittsfiler (de skulle göra varje sida flera hundra kB större). Moln på
  svenska använder Inter, och datorer utan Inter visar det nästa typsnittet i listan (Segoe UI).
