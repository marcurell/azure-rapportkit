# Azure Rapportkit

Ett PowerShell-script som tar fram underlag inför en genomgång av er Azure-miljö. Det körs **på en dator hos er, med ert konto**, hämtar några välkända analysverktyg (Azure Governance Visualizer, azqr och, om ni vill, Maester), läser Defender, Secure Score, kostnad, managementgrupper och nätverk, och sammanfattar allt i en rapport i flera sidor.

- Scriptet **skriver inget i era Azure-resurser** eller i Entra ID. Det använder bara läsande anrop.
- Resultatet sparas **lokalt** i en mapp ni väljer. Ingenting skickas någonstans av scriptet.
- Vad som sker, vilken data som hamnar i resultatet och vad som ändras på datorn står i [docs/KUNDINFO.md](docs/KUNDINFO.md). En kortfattad steg-för-steg-guide finns i `docs\Azure-Rapportkit-Kundguide.docx`.

## Innan ni börjar

| Behövs | Kommentar |
|---|---|
| En Windows-dator med internet | Windows 10 eller 11, ca 2 GB ledigt. Öppet mot github.com, powershellgallery.com, login.microsoftonline.com, management.azure.com och graph.microsoft.com. Scriptet kontrollerar detta först |
| Ett konto med rätt roller | På **Tenant Root Group**: Reader, Security Reader och Cost Management Reader. För Entra-testerna (Maester): Global Reader. Använder ni PIM: aktivera rollerna först. Scriptet kontrollerar rollerna direkt efter inloggningen och visar hur de läggs till |
| Tenant-ID | Entra ID > Overview > Tenant ID |
| Förvarning till säkerhetsteamet | Körningen gör många läsande anrop och loggar in från datorn. Berätta gärna för SOC/driftsäkerhet i förväg |
| Administratörsgodkännande (om Azure CLI saknas) | Azure CLI installeras av scriptet och ber då om administratörsgodkännande (UAC) |
| Admin consent för Maester (valfritt) | En Global Administrator behöver godkänna läsbehörigheter för *Microsoft Graph Command Line Tools* första gången. Hoppa över Maester med `-SkipMaester` om det inte passar |

## Starta

1. **Avblockera zip-filen:** högerklicka på zip-filen du fått, välj **Egenskaper**, kryssa i **Avblockera** (om rutan finns) och klicka OK. Windows blockerar annars script från e-post.
2. **Packa upp:** högerklicka på zip-filen och välj **Extrahera alla**.
3. **Öppna PowerShell** (inte ISE) i den uppackade mappen: håll Shift, högerklicka i mappen och välj *Öppna PowerShell-fönster här*, eller öppna PowerShell och gå dit med `cd`.
4. **Kör:**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-Rapportkit.ps1
```

Windows PowerShell 5.1 räcker: scriptet installerar PowerShell 7 om det behövs och fortsätter där. Körningen tar normalt 10 till 30 minuter beroende på miljöns storlek.

## Under körningen

Scriptet visar en ruta per steg (`STEP 3 OF 10`) och beskriver vad som händer. Meddelandena i fönstret är på engelska; rapporten får ni på svenska. Frågorna besvaras med **y** (ja) eller **n** (nej); **j** och **ja** fungerar också. Det frågar efter:

- **Tenant-ID** (ett förslag visas om ni redan är inloggade).
- **Var resultatet ska sparas.** Undvik OneDrive-mappar och mappar som synkas till molnet: resultatet är konfidentiellt.
- **Om resultatet ska krypteras med ett lösenord.** Svara **y** (ja) om filen ska skickas vidare. Ni väljer ett lösenord på minst 12 tecken (skrivs två gånger). Skriv ner det: det kan inte återskapas.
- **Om en anonymiserad version av rapporten ska skapas** (för demo eller delning). Normalt: nej.
- **Inloggning** i webbläsaren (Azure CLI, Azure PowerShell och, om Maester körs, Microsoft Graph).

Saknas en roll eller något annat viktigt får ni veta det direkt och väljer om ni vill fortsätta ändå. Scriptet kan avbrytas med Ctrl+C och köras om: det som redan är gjort återanvänds.

## När det är klart

Resultatet ligger i `<resultatmapp>\<år-månad>\`. Öppna `rapport.html` för att titta på det. Rapporten har sju sidor: Översikt, Struktur, Styrning, Resurser, Entra ID, Defender & kostnad och Om körningen. Knappen **Spara hela rapporten som PDF** samlar alla sidor. Rapportens språk är det kitet är förberett för (`-ReportLanguage`, till exempel `-ReportLanguage en` för engelska).

**Skicka resultatet till oss:**

1. Skicka filen `rapportkit_<tenant>_<år-månad>.zip.rkenc` (och gärna `.sha256`-filen bredvid) med e-post eller den kanal ni kommit överens om.
2. Skicka **lösenordet på ett annat sätt**, till exempel med SMS eller per telefon. Skicka aldrig lösenordet i samma meddelande som filen.
3. Ta bort resultatmappen från datorn när uppdraget är klart. Den innehåller okrypterade kopior.

Scriptet loggar ut de inloggningar det själv skapade när det är klart.

## Om något går fel

- Scriptet skriver vad som hänt, vad ni ska göra och exakt vilket kommando ni kör om. Ett verktyg som misslyckas stoppar inte de andra: rapporten visar det som gick bra.
- Skicka vid behov `rapportkit.log` från resultatmappen. Den innehåller inga lösenord eller tokens, men tenant-ID och namn på konton och resurser kan förekomma.

| Problem | Åtgärd |
|---|---|
| Scriptet blockeras | Avblockera zip-filen innan uppackning (steg 1 ovan), eller kör `Get-ChildItem -Recurse \| Unblock-File` i mappen |
| Roller saknas | Följ instruktionen som visas, eller be en Global Administrator höja åtkomsten och tilldela rollerna |
| Maester kräver godkännande | Be en Global Administrator godkänna, eller kör med `-SkipMaester` |
| Nedladdning misslyckas | Kontrollera proxy och brandvägg (se listan med adresser ovan) |
| Antivirus/EDR blockerar azqr | Be IT tillåta filen `azqr.exe` i resultatmappen |
| `429 Too Many Requests` i loggen | Normalt vid många anrop. Verktygen försöker igen automatiskt |

## Flaggor (valfria)

| Flagga | Betydelse |
|---|---|
| `-TenantId <guid>` | Hoppar över tenant-frågan |
| `-OutputRoot <mapp>` | Var resultatet sparas |
| `-SkipMaester` / `-SkipGovViz` / `-SkipAzqr` | Hoppa över ett verktyg |
| `-DeviceLogin` | Inloggning med kod i stället för webbläsarfönster |
| `-HidePersonalData` | Dölj namn och e-post i Governance Visualizers rapport |
| `-Anonymize` | Skapa även en anonymiserad rapport i mappen `anonym` |
| `-ReportLanguage <kod>` | Språk för rapportens text (`sv` eller `en`) |
| `-NoEncrypt` | Kryptera inte resultatpaketet (bara om det inte lämnar datorn) |
| `-KeepLogin` | Logga inte ut efter körningen |

## Licens och tredjepartsverktyg

Kitet ingår som MIT-licensierad programvara, se `LICENSE`. Verktygen som scriptet hämtar har sina egna licenser, se `THIRD-PARTY-NOTICES.md`. Kitet ges utan garanti, och rapporten är ett underlag för bedömning som inte ersätter en granskning av en kvalificerad person.
