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

Har kontot bara åtkomst till en subscription faller Governance Visualizer på behörighetskontrollen. De andra stegen körs ändå.

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
| `-NoPIMEligibility` | Använd om Governance Visualizer stoppar på PIM |
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

## Felsökning

| Problem | Åtgärd |
|---|---|
| `AuthorizationFailed` eller tomma resultat | Kontrollera att rollerna är aktiva (PIM) och tilldelade på rätt scope |
| Governance Visualizer: permission check FAILED | Reader saknas på Tenant Root Group, eller ange `-ManagementGroupId` |
| Governance Visualizer stoppar på PIM | Kör om med `-NoPIMEligibility` |
| `Connect-Maester` kräver godkännande | En Global Administrator måste ge admin consent för Microsoft Graph Command Line Tools |
| Skript blockeras | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` i samma fönster |

Loggen från körningen sparas i `rapportkit.log` i resultatmappen.

## Känt

- Scriptet patchar den hämtade kopian av Governance Visualizer så att den inte ställer en y/n-fråga om moduler. Det kan sluta fungera om verktyget ändrar den koden.
- Resultatmapparna innehåller konfidentiell information. De ligger utanför repot och ska aldrig checkas in.
