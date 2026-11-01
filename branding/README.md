# Branding: utseendet på rapporten

Rapporten byggs av en mall (tema) som du kan byta utan att ändra någon kod. Ett tema är en mapp:

```
branding\
  molnpasvenska\        <- ett tema (standard just nu)
    theme.json          <- färger, typsnitt, logga, sidfot
    logo.svg            <- valfritt: en logga som bildfil (om du inte använder ordbild)
    custom.css          <- valfritt: egna CSS-regler som läggs sist
  neutral\              <- ett neutralt reservtema
```

## Välj tema

| Hur | Exempel |
|---|---|
| Ett tema efter namn | `.\Run-Rapportkit.ps1 -Brand molnpasvenska` |
| En mapp var som helst | `.\Run-Rapportkit.ps1 -BrandPath D:\teman\mitt-tema` |
| Ett standardtema för den här datorn | skriv temats namn på en rad i `%USERPROFILE%\.rapportkit\brand.txt` |

Ett temanamn letas upp i tur och ordning i: `branding-local\` bredvid scriptet, `%USERPROFILE%\.rapportkit\themes\` och `branding\` (det som följer med kitet).
`branding-local\` ingår aldrig i repot (se `.gitignore`).

Anges inget används `brand.txt` om den finns, annars `molnpasvenska`. Saknas temat eller är något ogiltigt faller rapporten tillbaka på inbyggda
standardvärden och scriptet skriver en varning. Det blir aldrig en trasig rapport.

## Teman som inte ska ligga i det publika repot

Ett tema för ett eget företags eller en kunds varumärke bör inte checkas in i ett öppet repo. Lägg det i
`%USERPROFILE%\.rapportkit\themes\<namn>` (gäller för alla versioner av kitet, så det behöver bara göras en gång per
dator) och skriv `<namn>` i `%USERPROFILE%\.rapportkit\brand.txt` för att göra det till standard. Mappen kan kopieras
mellan datorer. Ta bort `brand.txt` för att gå tillbaka till standardtemat.

## Skapa ett nytt tema

1. Kopiera `branding\neutral` till `branding\<ditt-namn>`.
2. Ändra `theme.json` (se nedan).
3. Kör `.\Run-Rapportkit.ps1 -Brand <ditt-namn> -ReportOnly` på en befintlig resultatmapp för att se resultatet
   direkt utan att köra om verktygen.

## theme.json

| Fält | Betydelse |
|---|---|
| `name` | Temats namn (visas under "Om körningen") |
| `reportTitle` | Rapportens titel i sidhuvudet |
| `logo` | Se nedan |
| `colors.light`, `colors.dark` | Färgpalett för ljust respektive mörkt läge (följer läsarens inställning). Utskrift använder alltid ljust |
| `colors.status` | Färger för `high`, `medium`, `low` och `ok` (etiketter och kort) |
| `fonts.body`, `fonts.heading` | Typsnittslistor (CSS `font-family`). Typsnitt som inte finns på läsarens dator ersätts av nästa i listan |
| `footer` | Text i sidfoten |
| `contact` | `text` och `url` för en kontaktlänk i sidfoten (lämna tomt för att utelämna) |
| `background` | `file` (bild i temamappen, högst 500 KB) och `opacity` (0 till 1, standard 0,08). Visas bakom innehållet, inte vid utskrift |
| `customCss` | Filnamn på en CSS-fil i temamappen (valfritt) |

Färger i `colors.*`: `bg`, `surface`, `surfaceAlt`, `border`, `text`, `muted`, `accent` (profilfärg), `accentText`
(profilfärg för text och länkar, måste vara läsbar mot `surface`) och `onAccent` (text ovanpå profilfärgen). Värden
kan vara `#rrggbb`, `rgb(...)`, `hsl(...)` eller ett färgnamn.

### Logga

Antingen en **ordbild** (text i färger), som Moln på svenska:

```json
"logo": { "type": "wordmark", "parts": [ { "text": "Molnpå", "color": "text" }, { "text": "svenska", "color": "accent" } ] }
```

(`color` är `text`, `accent`, `accentText` eller `muted`.) Eller en **bildfil** i temamappen (svg, png, jpg, gif eller
webp, högst 300 KB). Den bäddas in i varje sida, så rapporten är fristående:

```json
"logo": { "type": "image", "file": "logo.svg", "fileDark": "logo-dark.svg", "alt": "Företagsnamn", "height": 36 }
```

`fileDark` är valfri: en logga som visas i stället när läsaren använder mörkt läge (till exempel en vit variant).

## Tänk på

- **Rättigheter:** använd bara ett varumärke (namn, logga, färger) som du har rätt att använda. Ett tema för någon
  annans varumärke, till exempel en partners eller kunds, kräver deras tillstånd.
- **Tema från okänd källa:** `theme.json` valideras (färger och typsnitt kontrolleras, och bara kända färgnamn tillåts i
  loggan), men `custom.css` läggs in som den är. Granska den innan du använder ett tema du inte skrivit själv.
- **Typsnitt:** rapporten bäddar inte in typsnittsfiler (de skulle göra varje sida flera hundra kB större). Moln på
  svenska använder Inter, och datorer utan Inter visar det nästa typsnittet i listan (Segoe UI).
