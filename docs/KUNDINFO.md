# Azure Rapportkit: information till kunden

Det här dokumentet beskriver vad scriptet gör, vad det rör och vad ni behöver förbereda. Det är skrivet för den som ska godkänna körningen hos er: IT, säkerhet och dataskydd.

## Kort sammanfattning

- Scriptet körs **på en dator hos er**, med **ert konto** och **era behörigheter**. Det kopplar inte upp sig mot något system hos oss.
- Det **skriver inget i Azure-resurser** eller i Entra-konfigurationen. Det använder läsande anrop.
- Resultatet (rapporter och loggar) sparas **lokalt** i en mapp ni väljer. Det är ni som bestämmer om och hur det lämnas vidare.
- All kod är öppen och går att granska: https://github.com/marcurell/azure-rapportkit

## Vad scriptet gör

| Steg | Vad som händer | Behörighet |
|---|---|---|
| Förkontroll | Kontrollerar dator, nätverk och verktyg innan något hämtas | Ingen |
| Inloggning | Azure CLI, Azure PowerShell och (valfritt) Microsoft Graph via webbläsaren | Ert konto |
| Rollkontroll | Läser vilka roller kontot har | Läsning |
| Governance Visualizer | Läser management groups, policys och rolltilldelningar | Reader |
| azqr | Läser resurser och jämför mot Microsofts rekommendationer | Reader |
| Defender och kostnad | Läser Defender-planer, Secure Score, rekommendationer och kostnad | Security Reader, Cost Management Reader |
| Maester (valfritt) | Läser Entra ID-inställningar via Microsoft Graph | Global Reader |

## Roller som behövs

Kontot som kör scriptet behöver, på **Tenant Root Group**:

- **Reader**
- **Security Reader**
- **Cost Management Reader**

samt, om Maester ska köras, **Global Reader** i Entra ID. Scriptet kontrollerar rollerna direkt efter inloggningen och visar hur de läggs till om något saknas.

Använder ni Privileged Identity Management (PIM): aktivera rollerna innan körningen.

## Vad scriptet ändrar (helt öppet)

Scriptet skriver inte i era Azure-resurser. Det gör däremot följande:

1. **Installerar verktyg på datorn** som kör det: PowerShell 7, Azure CLI och azqr (via winget), Azure Governance Visualizer (hämtas som zip från GitHub) samt PowerShell-moduler (Az.Accounts, Maester, Pester) från PowerShell Gallery. Versionerna är fastlåsta till de som är testade, och nedladdade zip-filer kontrolleras mot kontrollsumma (SHA256).
2. **Skapar inloggningssessioner.** De syns i Entra ID:s inloggningsloggar och i Azures aktivitetsloggar. Scriptet loggar ut de sessioner det själv skapade när det är klart (om inte annat valts).
3. **Maester kräver ett godkännande.** Första gången måste en Global Administrator godkänna läsbehörigheter för *Microsoft Graph Command Line Tools* (admin consent). Det är en ändring i tenanten. Hoppar ni över Maester behövs inget godkännande.
4. **Sparar filer lokalt** i den mapp ni väljer, och en zip-fil av resultatet.

## Ge SOC/driftsäkerhet en förvarning

Körningen genererar många läsande API-anrop mot Azure Resource Manager och Resource Graph, och i vissa miljöer svar med `429 Too Many Requests`. Inloggningarna sker från den dator som kör scriptet. Informera gärna ert säkerhetsteam i förväg så att det inte tolkas som en attack.

## Vilken data hamnar i resultatet

Resultatet beskriver er miljö och är **konfidentiellt**:

- struktur: management groups, prenumerationer, resursgrupper och resurser
- säkerhetsläge: policys, Secure Score, Defender-planer, rekommendationer
- behörigheter: **rolltilldelningar med namn och e-postadresser**
- kostnad: månadskostnad per prenumeration för de senaste 12 månaderna
- Entra ID-inställningar och testresultat (om Maester körs)

Önskar ni dölja namn och e-postadresser i Governance Visualizers rapport: kör med `-HidePersonalData`. Observera att Maesters rapport ändå kan innehålla användarnamn.

## Rapporten och internet

Rapportsidorna som scriptet skapar (`rapport*.html`) är fristående: stil, logga och bilder ligger inbäddade, och de hämtar **ingenting** från internet när de öppnas. Länkar till andra sidor eller verktyg öppnas i nytt fönster.

Undantaget är **Azure Governance Visualizers egen rapport** (filen `AzGovViz_*.html` i mappen `azgovviz\`, som rapporten länkar till som fördjupning). Den är inte fristående: när den öppnas hämtar webbläsaren dess formatmall, skript och ikoner från internet, bland annat `www.azadvertizer.net`, `cdnjs.cloudflare.com` och `code.jquery.com`. Det innebär att den inte visas rätt utan internetåtkomst, och att dessa adresser får se webbläsarens anrop. Vill ni undvika det: öppna inte den filen, utan använd sammanställningen på rapportsidan Styrning (som bygger på samma data) eller ta bort filen innan resultatet delas.

Rapportens utseende (färger, logga, sidfot) styrs av ett tema som kan bytas, se `branding\README.md`.

## Hur resultatet lämnas över

- Scriptet skapar en zip-fil med en tillhörande kontrollsumma (`.sha256`) så att mottagaren kan kontrollera att filen inte ändrats.
- Scriptet frågar efter ett **lösenord** (minst 12 tecken) i början av körningen och krypterar zip-filen med det (AES-256). Filen heter `rapportkit_<tenant>_<period>.zip.rkenc`. Skicka filen och lösenordet **på olika vägar** (till exempel filen via e-post och lösenordet via SMS eller telefon). Lösenordet sparas inte någonstans av scriptet.
- Mappen med de okrypterade resultaten ligger kvar på datorn som körde scriptet. Ta bort den när uppdraget är klart.
- Scriptet skickar inget resultat någonstans själv.

## Så granskar ni scriptet innan körning

1. Läs koden på GitHub (`Run-Rapportkit.ps1`). Den är kommenterad rad för rad.
2. Kontrollera att versionen ni kör är en släppt version (https://github.com/marcurell/azure-rapportkit/releases).
3. Kör gärna först med `-SkipMaester` och i en testmiljö.
4. Behöver datorn vara helt utan internet under körningen: be om offline-paketet (`Build-Bundle.ps1`), som innehåller alla verktyg.

## Fastlåsta verktyg och licenser

Se `THIRD-PARTY-NOTICES.md` för vilka tredjepartsverktyg som används, i vilka versioner och under vilka licenser.

## Om något går fel

Scriptet skriver tydliga felmeddelanden och vad ni ska göra, och ger ett kommando för att köra om. Det som redan är installerat återanvänds. Skicka vid behov `rapportkit.log` från resultatmappen. Den innehåller inga lösenord eller tokens, men tenant-ID och namn på konton och resurser kan förekomma.
