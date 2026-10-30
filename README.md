# azure-rapportkit

Ett PowerShell-script som tar fram underlag inför en Azure-genomgång. Det hämtar verktygen, loggar in, kör tre gratis read-only-verktyg och sammanfattar resultatet i en HTML-rapport.

| Verktyg | Vad det ger |
|---|---|
| [Azure Governance Visualizer](https://github.com/Azure/Azure-Governance-Visualizer) | Management groups, policies, rolltilldelningar |
| [azqr](https://github.com/Azure/azqr) | Rekommendationer per resurs, Advisor, Defender |
| [Maester](https://maester.dev) (valfritt) | Tester av Entra ID: MFA, Conditional Access, privilegierade roller |

Scriptet ändrar ingenting i Azure eller Entra. Det som installeras hamnar på datorn som kör det.

## Snabbstart: ett kommando

Öppna PowerShell eller PowerShell ISE och klistra in blocket nedan. Det laddar ner koden från den senaste releasen (utan git), packar upp den, avblockerar filerna och startar scriptet i ett nytt PowerShell-fönster. Följ instruktionerna i det fönstret.

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dest = Join-Path $env:USERPROFILE 'rapportkit-kit'
$zip  = Join-Path $env:TEMP 'azure-rapportkit.zip'
New-Item -ItemType Directory -Force $dest | Out-Null
Invoke-WebRequest 'https://github.com/marcurell/azure-rapportkit/archive/refs/tags/v1.0.2.zip' -OutFile $zip
Expand-Archive $zip $dest -Force
Get-ChildItem $dest -Recurse | Unblock-File
$script = Join-Path $dest 'azure-rapportkit-1.0.2\Run-Rapportkit.ps1'
$arg = '-NoExit -ExecutionPolicy Bypass -File "' + $script + '"'
Start-Process powershell -ArgumentList $arg
```

Varför ett nytt fönster: PowerShell ISE klarar inte inloggningsfönster och frågor från PowerShell 7, så scriptet ska inte köras direkt i ISE.

Du behöver ha tenant-ID:t till hands (Entra ID > Overview > Tenant ID). Scriptet frågar efter det, och därefter öppnas två inloggningsfönster i webbläsaren.

## Ladda ner manuellt

Vill du inte använda kommandot ovan: gå till **Releases** i det här repot och ladda ner `Source code (zip)` för senaste versionen.

1. Spara zippen, högerklicka på den, välj **Egenskaper**, kryssa i **Avblockera** och klicka OK. (Windows blockerar annars script som hämtats från internet.)
2. Högerklicka på zippen och välj **Extrahera alla**.
3. Fortsätt med "Kör scriptet" nedan.

Vill du hellre använda git: `git clone https://github.com/marcurell/azure-rapportkit.git`

## Kör scriptet

Öppna ett vanligt PowerShell-fönster (inte ISE) i mappen med scriptet. Windows PowerShell 5.1 räcker: scriptet installerar PowerShell 7 och startar om sig självt där. Kör:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-Rapportkit.ps1
```

Under körningen skriver scriptet ut vilket steg det är på (`Steg 3/7: Inloggning`), vad det gör just nu (`->`), och vad du själv behöver göra (`>>>`).

Resultatet hamnar i `C:\rapportkit\<år-månad>\`, med `rapport.html` som sammanfattning.

## Behörigheter

Kontot som loggar in behöver:

| Roll | Scope | Behövs för |
|---|---|---|
| Reader | Tenant Root Group | Governance Visualizer, azqr |
| Security Reader | Tenant Root Group | Defender-uppgifter i azqr |
| Cost Management Reader | Tenant Root Group | Kostnadsöversikt (manuell export) |
| Global Reader | Microsoft Entra ID | Maester |

Har kontot bara åtkomst till en subscription faller Governance Visualizer på behörighetskontrollen (tenant root kräver Reader). De andra stegen körs ändå.

## Steg

1. **Förberedelser**: tenant-ID, resultatmappar, loggfil.
2. **Förkontroll**: kontrollerar verktyg, nätverk (GitHub, PowerShell Gallery, inloggning, Azure, Graph), diskutrymme och om frågor kan besvaras, innan något hämtas. Saknas något visas det tydligt och du väljer om du vill fortsätta ändå.
3. **Beroenden**: hämtar det som saknas. PowerShell 7, Azure CLI och azqr via winget (azqr annars direkt från GitHub), Governance Visualizer som zip från GitHub, moduler från PowerShell Gallery till `C:\rapportkit\_modules`.
4. **Inloggning**: Azure CLI, Az PowerShell och valfritt Microsoft Graph. Därefter kontrolleras om kontot kan läsa management group som Governance Visualizer startar på; kan det inte får du välja att köra ändå eller hoppa över verktyget.
5. **Governance Visualizer**
6. **azqr**
7. **Maester**
8. **HTML-rapport**

## Flaggor

| Flagga | Betydelse |
|---|---|
| `-TenantId <guid>` | Hoppar över tenant-frågan |
| `-ManagementGroupId <id>` | Kör Governance Visualizer mot annan management group än tenant root |
| `-SkipGovViz` / `-SkipAzqr` / `-SkipMaester` | Hoppa över ett verktyg |
| `-DeviceLogin` | Inloggning med kod istället för webbläsarfönster |
| `-NoInstall` | Hämta och installera ingenting |
| `-Offline` | Ladda inte ner något, använd bara `tools\` (se nedan) |
| `-ReportOnly` | Bygg bara om HTML-rapporten från befintliga resultat |
| `-Yes` | Svara ja på alla "fortsätta ändå?"-frågor (för automatiska körningar) |
| `-OutputRoot` / `-Period` | Annan resultatmapp / månadsmapp |

## Offline-bundle

Kan kundens dator inte hämta saker själv: kör `Build-Bundle.ps1` på en dator med internet. Det laddar ner verktygen till `tools\` och packar scriptet och verktygen i `rapportkit-bundle.zip`. Kunden packar upp zippen och kör `.\Run-Rapportkit.ps1 -Offline`.

```powershell
.\Build-Bundle.ps1                  # med installers (~300 MB)
.\Build-Bundle.ps1 -SkipInstallers  # utan PowerShell/Azure CLI/Git
```

## Om något går fel

Scriptet är byggt för att avbrott ska vara begripliga:

- **Ett verktyg misslyckas:** de andra körs ändå. Felet och vad du ska göra syns i sammanfattningen i konsolen och i statustabellen överst i `rapport.html`.
- **Scriptet kan inte fortsätta** (till exempel ingen inloggning eller ingen internetåtkomst): det skriver orsaken, vad du ska göra och exakt vilket kommando du kör om. Det som redan är installerat återanvänds.
- **Du avbryter (Ctrl+C) eller stänger fönstret:** kör bara scriptet igen. Inget har ändrats i Azure.
- **Nedladdningar kontrolleras:** filstorlek, att zip-filer är hela och att förväntade filer finns. Misslyckade nedladdningar försöks 3 gånger.
- **Resultatfiler kontrolleras** innan rapporten byggs. Oväntat format visas som varning i rapporten istället för att stoppa den.

Slutkod: `0` = allt gick bra, `2` = något verktyg misslyckades men rapport finns, `1` = körningen avbröts.

## Felsökning

| Problem | Åtgärd |
|---|---|
| `AuthorizationFailed` eller tomma resultat | Kontrollera att rollerna är aktiva (PIM) och tilldelade på rätt scope |
| Governance Visualizer: permission check FAILED | Reader saknas på Tenant Root Group, eller ange `-ManagementGroupId` |
| Governance Visualizer väntar på tangenttryckning | Tryck Enter. Det kommer av en behörighetsvarning från verktyget; scriptet kör vidare |
| `Connect-Maester` kräver godkännande | En Global Administrator måste ge admin consent för Microsoft Graph Command Line Tools |
| Skript blockeras | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` i samma fönster |

Loggen från körningen sparas i `rapportkit.log` i resultatmappen.

## Licens

MIT, se [LICENSE](LICENSE). Verktygen som scriptet hämtar har sina egna licenser (Azure Governance Visualizer, azqr och Maester är alla öppna).

## Känt

- Governance Visualizer hämtas i en fast version (6.7.2) som scriptet är testat mot.
- Scriptet patchar den hämtade kopian av Governance Visualizer så att den inte ställer en y/n-fråga om moduler. Det kan sluta fungera om verktyget ändrar den koden.
- Resultatmapparna innehåller konfidentiell information. De ligger utanför repot och ska aldrig checkas in.
