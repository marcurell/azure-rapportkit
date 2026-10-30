# azure-rapportkit

Ett PowerShell-script som tar fram underlag inför en Azure-genomgång. Det hämtar verktygen, loggar in, kör tre gratis read-only-verktyg och sammanfattar resultatet i en HTML-rapport.

| Verktyg | Vad det ger |
|---|---|
| [Azure Governance Visualizer](https://github.com/Azure/Azure-Governance-Visualizer) | Management groups, policies, rolltilldelningar |
| [azqr](https://github.com/Azure/azqr) | Rekommendationer per resurs, Advisor, Defender |
| [Maester](https://maester.dev) (valfritt) | Tester av Entra ID: MFA, Conditional Access, privilegierade roller |

Scriptet ändrar ingenting i Azure eller Entra. Det som installeras hamnar på datorn som kör det.

## Ladda ner

Gå till **Releases** i det här repot och ladda ner `Source code (zip)` för senaste versionen. Du behöver inte installera git.

1. Spara zippen, högerklicka på den, välj **Egenskaper**, kryssa i **Avblockera** och klicka OK. (Windows blockerar annars script som hämtats från internet.)
2. Högerklicka på zippen och välj **Extrahera alla**.
3. Fortsätt med "Kom igång" nedan.

Vill du hellre använda git: `git clone https://github.com/marcurell/azure-rapportkit.git`

## Kom igång

Öppna PowerShell (Windows PowerShell 5.1 räcker, scriptet installerar PowerShell 7 och startar om sig självt där) och kör:

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
2. **Beroenden**: hämtar det som saknas. PowerShell 7, Azure CLI och azqr via winget (azqr annars direkt från GitHub), Governance Visualizer som zip från GitHub, moduler från PowerShell Gallery till `C:\rapportkit\_modules`.
3. **Inloggning**: Azure CLI, Az PowerShell och valfritt Microsoft Graph.
4. **Governance Visualizer**
5. **azqr**
6. **Maester**
7. **HTML-rapport**

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
