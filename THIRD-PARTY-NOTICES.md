# Third-party components

Azure Rapportkit (MIT, see `LICENSE`) fetches and runs the following tools. They are not part of the repo, but are fetched
when the script runs (or put in the offline bundle that `Build-Bundle.ps1` builds). Every component has its own licence. The
offline bundle contains the original archives and their licence files unchanged.

| Component | Version (tested) | Licence | Source |
|---|---|---|---|
| Azure Governance Visualizer (AzGovViz) | 6.7.2 | MIT | https://github.com/Azure/Azure-Governance-Visualizer |
| Azure Quick Review (azqr) | 4.3.0 | MIT | https://github.com/Azure/azqr |
| Maester | 2.3.0 | MIT | https://github.com/maester365/maester |
| Pester | 5.9.1 | Apache-2.0 | https://github.com/pester/Pester |
| Az.Accounts (Azure PowerShell) | 5.5.3 | Microsoft's licence for Azure PowerShell, see https://aka.ms/azps-license | https://github.com/Azure/azure-powershell |
| AzAPICall | 1.4.1 | MIT | https://github.com/JulianHayward/AzAPICall |
| Microsoft Graph PowerShell (Microsoft.Graph.Authentication) | fetched as a dependency of Maester | See https://aka.ms/devservicesagreement | https://github.com/microsoftgraph/msgraph-sdk-powershell |
| PowerShell 7 | installed with winget | MIT | https://github.com/PowerShell/PowerShell |
| Azure CLI | installed with winget | MIT | https://github.com/Azure/azure-cli |

## Changes to Azure Governance Visualizer

The script makes three small changes in a **local copy** of Governance Visualizer (the original on GitHub is not touched).
Every change is marked in the file with `RAPPORTKIT-`:

1. it does not ask about installing modules when the modules already exist in the script's own module folder,
2. it removes the advisory pauses that wait for a key press,
3. it skips the call to the retired classic administrators API, which otherwise stops the run.

The changes are tied to version 6.7.2. The script also runs Governance Visualizer with `-StatsOptOut`, so that it sends no
usage statistics to Microsoft Application Insights.

Maester's test suite is not downloaded separately: `Install-MaesterTests` copies the tests that come with the Maester module,
so they always belong to the Maester version that runs. PowerShell modules that already exist on the computer in an accepted
version are used as they are, also when they are newer than the tested version.

## Note

The versions above are the ones the script is tested with (see `$Pins` in `Run-Rapportkit.ps1`). The licences of
Governance Visualizer, azqr, Maester, AzAPICall, PowerShell and Azure CLI (MIT) and Pester (Apache-2.0) are checked against
each project's licence file or GitHub metadata. For Azure PowerShell and Microsoft Graph PowerShell, see Microsoft's own
licence pages above. Check the original source if it matters. With `-LatestTools` newer versions are fetched, which can
have other terms.
