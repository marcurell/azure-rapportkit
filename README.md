# azure-rapportkit

[![CI](https://github.com/marcurell/azure-rapportkit/actions/workflows/ci.yml/badge.svg)](https://github.com/marcurell/azure-rapportkit/actions/workflows/ci.yml)

Ett PowerShell-script som tar fram underlag inför en Azure-genomgång. Det hämtar verktygen, loggar in, kör tre gratis verktyg som bara läser och sammanfattar resultatet i en HTML-rapport.

| Verktyg | Vad det ger |
|---|---|
| [Azure Governance Visualizer](https://github.com/Azure/Azure-Governance-Visualizer) | Management groups, policies, rolltilldelningar |
| [azqr](https://github.com/Azure/azqr) | Rekommendationer per resurs, Advisor, Defender |
| [Maester](https://maester.dev) (valfritt) | Tester av Entra ID: MFA, Conditional Access, privilegierade roller |

Scriptet **skriver inget i Azure-resurser eller i Entra-konfigurationen**. Det gör däremot följande, vilket är bra att veta: det installerar verktyg på datorn, skapar inloggningssessioner (som syns i tenantens loggar), kräver att en administratör godkänner läsbehörigheter för Maester (admin consent, en ändring i tenanten), och sparar konfidentiella resultat lokalt. Allt detta beskrivs för kunden i [docs/KUNDINFO.md](docs/KUNDINFO.md). Verktygen och deras licenser finns i [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Steg för steg för den som kör verktyget: [Användarguide (Word)](docs/Anvandarguide-Azure-Rapportkit.docx).

## Snabbstart: ett kommando

Öppna PowerShell eller PowerShell ISE och klistra in blocket nedan. Det laddar ner koden från den senaste releasen (utan git), packar upp den, avblockerar filerna och startar scriptet i ett nytt PowerShell-fönster. Följ instruktionerna i det fönstret.

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dest = Join-Path $env:USERPROFILE 'rapportkit-kit'
$zip  = Join-Path $env:TEMP 'azure-rapportkit.zip'
New-Item -ItemType Directory -Force $dest | Out-Null
Invoke-WebRequest 'https://github.com/marcurell/azure-rapportkit/archive/refs/tags/v1.0.9.zip' -OutFile $zip
Expand-Archive $zip $dest -Force
Get-ChildItem $dest -Recurse | Unblock-File
$script = Join-Path $dest 'azure-rapportkit-1.0.9\Run-Rapportkit.ps1'
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

Under körningen visar scriptet en ruta per steg (`STEG 3 AV 10`) med förloppsstapel, färgade statusetiketter (`OK`, `VARNING`, `SAKNAS`, `FEL`) och `GÖR` när något är ditt att göra. Det avslutar med en sammanfattningsruta med tid per verktyg. Visas ramarna fel i din konsol: kör med `-Plain`.

Scriptet frågar först **var resultatet ska sparas** (förslag: `%USERPROFILE%\rapportkit`). Det varnar om mappen ligger i OneDrive (synkas till molnet) eller under Dokument/Skrivbord (Windows kan blockera skrivning). Ange `-OutputRoot <mapp>` för att hoppa över frågan.

## Resultat och loggar

Allt hamnar i `<resultatmapp>\<år-månad>\`:

| Fil | Innehåll |
|---|---|
| `rapport.html` (+ fem sidor) | Rapporten i en gemensam stil: **Översikt**, **Styrning**, **Resurser**, **Entra ID**, **Defender & kostnad** och **Om körningen**. Varje sida är fristående (stil och logga ligger inbäddade) och hämtar inget från internet |
| `azgovviz\`, `azqr\`, `maester\` | Verktygens egna rapporter |
| `portal\` | Defender- och kostnadsdata som CSV (inklusive Secure Score per kontroll) |
| `rapportkit.log` | Rensad logg med tidsstämpel och nivå |
| `rapportkit-console.log` | Hela konsolutskriften inklusive verktygens text (felsökning; tas inte med i zippen) |
| `run-summary.json` | Maskinläsbar sammanfattning: versioner, tid per steg, status, varningar, slutkod |

Utanför mappen: `rapportkit_<tenant>_<år-månad>.zip` med en `.sha256`-fil, så att mottagaren kan kontrollera att filen kommit fram oförändrad (stäng av med `-NoZip`). Zippen är inte krypterad.

**Utloggning:** scriptet loggar ut de sessioner (Azure CLI, Azure PowerShell, Microsoft Graph) som det själv skapade när det är klart. En inloggning som fanns innan rörs inte. Stäng av med `-KeepLogin`.

## Utseende (branding)

Rapporten är en flersidig webbplats i en gemensam stil, med navigering, ljust och mörkt läge (följer läsarens inställning) och utskriftsläge. Knappen "Spara hela rapporten som PDF" öppnar en sammanställning av alla sidor (`rapport-komplett.html`) och visar utskriftsdialogen. Utseendet styrs av ett **tema**: en mapp med `theme.json` (färger, typsnitt, logga, sidfot) och eventuellt en logofil och egen CSS. Standardtemat är `molnpasvenska`; det finns också `neutral` och `orange` (Orange Business-färger, platshållarlogga: se `branding/orange/README.md`).

```powershell
.\Run-Rapportkit.ps1 -Brand orange                   # ett annat tema i branding\
.\Run-Rapportkit.ps1 -BrandPath D:\teman\kundnamn    # ett tema var som helst
.\Run-Rapportkit.ps1 -ReportOnly -Brand neutral      # bygg om rapporten från befintliga resultat, utan att köra verktygen
```

Se [branding/README.md](branding/README.md) för hur du skapar ett eget tema. Saknas eller är något ogiltigt i ett tema används inbyggda standardvärden och scriptet varnar.

**Verktygens egna rapporter** (Governance Visualizer, Maester, azqr:s Excel) går inte att göra om till samma stil, så de länkas som fördjupning och öppnas i nytt fönster. Observera att Governance Visualizers egen rapport hämtar sin stil, sina skript och sina ikoner från internet (bland annat `www.azadvertizer.net` och `cdnjs.cloudflare.com`), och därför inte visas rätt offline. Sidorna i det här kitet gör inga externa anrop.

## Behörigheter

Kontot som loggar in behöver:

| Roll | Scope | Behövs för |
|---|---|---|
| Reader | Tenant Root Group | Governance Visualizer, azqr |
| Security Reader | Tenant Root Group | Defender-rekommendationer och Secure Score |
| Cost Management Reader | Tenant Root Group | Kostnad de senaste 12 månaderna |
| Global Reader | Microsoft Entra ID | Maester |

**Rollerna kontrolleras direkt efter inloggningen (steg 3), innan något mer hämtas.** Saknas en roll visar scriptet vilka kommandon som lägger till den och frågar om du vill fortsätta ändå. Standardsvaret är nej, och då avslutas körningen med instruktionen. Global Administrator i Entra ID ger inte automatiskt Azure-roller: se avsnittet "Ge dig själv läsrätt på tenant root" nedan.

Har kontot bara åtkomst till en subscription faller Governance Visualizer på behörighetskontrollen, eftersom verktyget måste kunna läsa management group på tenant root. De andra stegen körs ändå.

**Om rollen Reader:** Governance Visualizer kontrollerar bara att management group går att läsa, så vilken roll som ger läsrätten spelar ingen roll (även User Access Administrator räcker tekniskt). Reader rekommenderas eftersom den ger minst rättigheter. Har kontot fler roller än Reader skriver verktyget en "least privilege"-rekommendation; scriptet låter inte den pausa körningen. Rollen **Management Group Reader** är något annat än **Reader**: den ger bara läsrätt på gruppstrukturen, inte på resurserna.

**Kontrollera scopet:** rollerna ska ligga på **Tenant Root Group** (Management groups > Tenant Root Group > Access control (IAM) > Role assignments), inte på en prenumeration eller resursgrupp.

## Steg

1. **Förberedelser**: tenant-ID, resultatmappar, loggfil.
2. **Förkontroll**: kontrollerar verktyg, nätverk (GitHub, PowerShell Gallery, inloggning, Azure, Graph), diskutrymme och om frågor kan besvaras, innan något hämtas. Saknas något visas det tydligt och du väljer om du vill fortsätta ändå.
3. **Azure CLI, inloggning och rollkontroll**: installerar Azure CLI om det saknas, loggar in och kontrollerar kontots roller (Azure och Entra). Saknas roller får du instruktionen och väljer att avsluta eller fortsätta.
4. **Beroenden**: hämtar det som saknas, i **fasta, testade versioner**. PowerShell 7 och azqr via winget (azqr annars direkt från GitHub), Governance Visualizer som zip från GitHub och moduler från PowerShell Gallery till `<resultatmapp>\_modules`. Zip-filerna kontrolleras mot SHA256-kontrollsummor, och en ändrad fil stoppar körningen (se `-AllowUnverified`).
5. **Inloggning**: Az PowerShell och valfritt Microsoft Graph. Därefter kontrolleras om kontot kan läsa management group som Governance Visualizer startar på.
6. **Governance Visualizer**
7. **azqr**
8. **Maester**
9. **Defender och kostnad**: hämtar automatiskt Defender-planer, Secure Score (även per kontroll), Defender-rekommendationer och kostnad per månad för de senaste 12 månaderna, via Azure Resource Manager (read-only). Sparas som CSV i `portal\`. Det som tidigare var manuella exporter från portalen.
10. **HTML-rapport**

## Flaggor

| Flagga | Betydelse |
|---|---|
| `-TenantId <guid>` | Hoppar över tenant-frågan |
| `-ManagementGroupId <id>` | Kör Governance Visualizer mot annan management group än tenant root |
| `-SkipGovViz` / `-SkipAzqr` / `-SkipMaester` / `-SkipPortal` | Hoppa över ett verktyg (`-SkipPortal` = Defender och kostnad) |
| `-DeviceLogin` | Inloggning med kod istället för webbläsarfönster |
| `-NoInstall` | Hämta och installera ingenting |
| `-Offline` | Ladda inte ner något, använd bara `tools\` (se nedan) |
| `-ReportOnly` | Bygg bara om HTML-rapporten från befintliga resultat |
| `-Yes` | Svara ja på alla "fortsätta ändå?"-frågor (för automatiska körningar) |
| `-MaxPortalSubscriptions <n>` | Högst så många aktiva prenumerationer hämtas Defender- och kostnadsdata för (standard 25) |
| `-OutputRoot <mapp>` | Resultatmapp. Anges den inte frågar scriptet |
| `-Period <namn>` | Namn på undermappen för körningen (standard: innevarande månad, `yyyy-MM`) |
| `-HidePersonalData` | Dölj namn och e-postadresser i Governance Visualizers rapport (Maesters rapport kan ändå innehålla namn) |
| `-KeepLogin` | Logga inte ut från sessioner som scriptet skapade |
| `-NoZip` | Skapa ingen zip av resultatet |
| `-Plain` | Rita ramar med ASCII-tecken (för konsoler som visar specialtecken fel) |
| `-LatestTools` | Använd senaste verktygsversioner istället för de testade, och hoppa över kontrollsummor |
| `-AllowUnverified` | Fortsätt trots att en kontrollsumma inte stämmer. Använd bara efter egen kontroll |
| `-Brand <namn>` | Rapportens utseende: ett tema i `branding\` (standard `molnpasvenska`) |
| `-BrandPath <mapp>` | Ett tema i en valfri mapp (går före `-Brand`) |

## Offline-bundle

Kan kundens dator inte hämta saker själv: kör `Build-Bundle.ps1` på en dator med internet. Det laddar ner de fasta versionerna till `tools\` (kontrollsummorna kontrolleras), och packar scriptet, verktygen, licenstexterna och kundinformationen i `rapportkit-bundle.zip` med en `.sha256`-fil. Kunden packar upp zippen och kör `.\Run-Rapportkit.ps1 -Offline`.

```powershell
.\Build-Bundle.ps1                  # med installers (~300 MB)
.\Build-Bundle.ps1 -SkipInstallers  # utan PowerShell/Azure CLI/Git
```

### Ge dig själv läsrätt på tenant root (görs av en Global Administrator)

1. Entra ID > Properties > **Access management for Azure resources** = Yes > Save. (Ger tillfälligt rollen User Access Administrator på scope `/`.) Logga ut och in igen.
2. Kör, med ett konto som nu har rätten:

```powershell
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Reader" --scope "/"
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Security Reader" --scope "/"
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Cost Management Reader" --scope "/"
```

3. Sätt **Access management for Azure resources** tillbaka till No.

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
| Governance Visualizer: permission check FAILED, trots att du är Global Administrator | Global Administrator i Entra ID ger **inte** åtkomst till Azure-resurser. Höj åtkomsten tillfälligt: Entra ID > Properties > **Access management for Azure resources** = Yes. Tilldela sedan dig själv Reader (och Security Reader, Cost Management Reader) på scope `/`, och sätt reglaget tillbaka till No. Kommandon finns i avsnittet nedan |
| Windows Defender: "Unauthorized changes blocked" för `pwsh.exe` | Kontrollerad mappåtkomst (ransomware-skydd) blockerar skrivning till en skyddad mapp. Notifieringen anger mappen: öppna Windows Security > Virus & threat protection > Ransomware protection > Block history. Låt scriptet skriva till en mapp som inte är skyddad (`-OutputRoot C:\rapportkit`) eller tillåt `C:\Program Files\PowerShell\7\pwsh.exe` under "Allow an app through Controlled folder access". Hanteras säkerhetsinställningen av IT får de göra det |
| Governance Visualizer: `check FAILED` | Kontot kan inte läsa management group. Tilldela Reader på **Tenant Root Group** (kontrollera scopet), eller ange `-ManagementGroupId` |
| Governance Visualizer visar "LEAST PRIVILEGE ADVICE" | Informationsmeddelande: kontot har fler roller än Reader. Inget fel; scriptet låter den inte pausa körningen |
| Governance Visualizer stoppar på `classicAdministrators` (404) | Fixat: det pensionerade API:et hoppas över i den lokala kopian (klassiska administratörer rapporteras därför inte) |
| `Connect-Maester` kräver godkännande | En Global Administrator måste ge admin consent för Microsoft Graph Command Line Tools |
| Skript blockeras | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` i samma fönster. Styrs körpolicyn av grupprincip gäller inte Bypass; förkontrollen visar det |
| Inloggningen misslyckas med `AADSTS53003`, `AADSTS50076` m.fl. | Tenantens villkorsstyrda åtkomst (Conditional Access) stoppar inloggningen. Be IT tillåta apparna "Microsoft Azure CLI", "Azure PowerShell" och "Microsoft Graph Command Line Tools" för ditt konto, eller kör från en hanterad/kompatibel dator |
| Rollerna "saknas" fast du har dem via PIM | Aktivera rollerna först (Entra ID > Privileged Identity Management > My roles) och kör om |
| Nedladdningar misslyckas bakom företagsproxy | Scriptet skickar med Windows-inloggningen till proxyn. Hjälper det inte: kontrollera att github.com, objects.githubusercontent.com och www.powershellgallery.com släpps igenom, eller använd offline-bundlen (`Build-Bundle.ps1`) |
| Förkontrollen säger "begränsat läge" (AppLocker/WDAC) | Scriptet kan inte köras i Constrained Language Mode. Be IT om undantag, eller kör på en annan dator |
| `azqr går inte att köra` | Antivirus/EDR/AppLocker blockerar den nedladdade `azqr.exe`. Be IT tillåta den |

Skicka `rapportkit.log` (och vid behov `rapportkit-console.log`) från resultatmappen när du ber om hjälp. Loggarna innehåller inga lösenord eller tokens, men tenant-ID och namn på konton och resurser kan förekomma.

## Licens

MIT, se [LICENSE](LICENSE). Verktygen som scriptet hämtar har sina egna licenser, se [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Känt

- Governance Visualizer hämtas i en fast version (6.7.2) som scriptet är testat mot.
- Scriptet patchar den hämtade kopian av Governance Visualizer (den i `<resultatmapp>\Azure-Governance-Visualizer-6.7.2`, originalet på GitHub rörs inte) på tre ställen: ingen y/n-fråga om moduler, inga pauser på tangenttryckning, och det pensionerade classic administrators-API:et hoppas över. Patcharna är knutna till version 6.7.2 och kan sluta fungera om verktyget ändras; scriptet varnar om en patch inte kunde tillämpas.
- Governance Visualizer körs med `-NoPIMEligibility` (kräver servicekonto) och `-NoALZPolicyVersionChecker` (kräver git och GitHub).
- Resultatmapparna innehåller konfidentiell information. De ligger utanför repot och ska aldrig checkas in.
- Defender-rekommendationer hämtas från Azures API, som kan returnera en ofullständig lista. Därför hämtas även Secure Score per kontroll, och scriptet varnar när de inte stämmer överens.
- Utveckling: `tests\` innehåller enhetstester (Pester) och `.github\workflows\ci.yml` kör syntaxkontroll i PowerShell 5.1 och 7, statisk analys, testerna, samt en kontroll varje vecka att de pinnade kontrollsummorna fortfarande stämmer uppströms.
