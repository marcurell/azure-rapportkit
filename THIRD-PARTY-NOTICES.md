# Tredjepartskomponenter

Azure Rapportkit (MIT, se `LICENSE`) hämtar och kör följande verktyg. De ingår inte i repot, utan hämtas vid körning
(eller läggs i offline-paketet som byggs med `Build-Bundle.ps1`). Varje komponent har sin egen licens. Offline-paketet
innehåller originalarkiven och deras licensfiler oförändrade.

| Komponent | Version (testad) | Licens | Källa |
|---|---|---|---|
| Azure Governance Visualizer (AzGovViz) | 6.7.2 | MIT | https://github.com/Azure/Azure-Governance-Visualizer |
| Azure Quick Review (azqr) | 4.3.0 | MIT | https://github.com/Azure/azqr |
| Maester | 2.3.0 | MIT | https://github.com/maester365/maester |
| Pester | 5.9.1 | Apache-2.0 | https://github.com/pester/Pester |
| Az.Accounts (Azure PowerShell) | 5.5.3 | Microsofts licens för Azure PowerShell, se https://aka.ms/azps-license | https://github.com/Azure/azure-powershell |
| AzAPICall | 1.4.1 | MIT | https://github.com/JulianHayward/AzAPICall |
| Microsoft Graph PowerShell (Microsoft.Graph.Authentication) | hämtas som beroende till Maester | Se https://aka.ms/devservicesagreement | https://github.com/microsoftgraph/msgraph-sdk-powershell |
| PowerShell 7 | installeras via winget | MIT | https://github.com/PowerShell/PowerShell |
| Azure CLI | installeras via winget | MIT | https://github.com/Azure/azure-cli |

## Ändringar i Azure Governance Visualizer

Scriptet gör tre små ändringar i en **lokal kopia** av Governance Visualizer (originalet på GitHub rörs inte). Varje
ändring är märkt i filen med `RAPPORTKIT-`:

1. frågar inte om modulinstallation när modulerna redan finns i scriptets egen modulmapp,
2. tar bort de rådgivande pauserna som väntar på tangenttryckning,
3. hoppar över anropet till det pensionerade classic administrators-API:et, som annars stoppar körningen.

Ändringarna är knutna till version 6.7.2.

## Obs

Versionsuppgifterna ovan är de som scriptet är testat med (se `$Pins` i `Run-Rapportkit.ps1`). Licenserna för
Governance Visualizer, azqr, Maester, AzAPICall, PowerShell och Azure CLI (MIT) samt Pester (Apache-2.0) är
kontrollerade mot respektive projekts licensfil eller GitHub-metadata. För Azure PowerShell och Microsoft Graph PowerShell
hänvisas till Microsofts egna licenssidor ovan. Kontrollera originalkällan om det är viktigt. Med `-LatestTools` hämtas nyare versioner som
kan ha andra villkor.
