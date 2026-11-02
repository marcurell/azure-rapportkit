# Azure Rapportkit: information for the customer

This document describes what the script does, what it touches and what you need to prepare. It is written for whoever approves the run at your organisation: IT, security and data protection.

## Short summary

- The script runs **on a computer at your site**, with **your account** and **your permissions**. It does not connect to any system on our side.
- It **writes nothing to Azure resources** or to the Entra configuration. It makes read calls only.
- The result (reports and logs) is saved **locally** in a folder you choose. You decide whether and how it is passed on.
- All the code is included in the kit and can be reviewed: `Run-Rapportkit.ps1` is commented line by line and the rest is in the folder `lib\`.

## What the script does

| Step | What happens | Permission |
|---|---|---|
| Pre-flight | Checks the computer, network and tools before anything is fetched | None |
| Sign-in | Azure CLI, Azure PowerShell and (optionally) Microsoft Graph through the browser | Your account |
| Role check | Reads which roles the account has | Read |
| Governance Visualizer | Reads management groups, policies and role assignments | Reader |
| azqr | Reads resources and compares them with Microsoft's recommendations | Reader |
| Defender and cost | Reads Defender plans, Secure Score, recommendations and cost | Security Reader, Cost Management Reader |
| Structure | Reads management groups, virtual networks, peerings and network nodes (Azure Resource Graph) | Reader |
| Maester (optional) | Reads Entra ID settings through Microsoft Graph | Global Reader |

## Roles that are needed

The account that runs the script needs, on the **Tenant Root Group**:

- **Reader**
- **Security Reader**
- **Cost Management Reader**

and, if Maester is to be run, **Global Reader** in Entra ID. The script checks the roles right after sign-in and shows how to add them if something is missing.

If you use Privileged Identity Management (PIM): activate the roles before the run.

## What the script changes (in the open)

The script does not write to your Azure resources. It does, however, do the following:

1. **Installs tools on the computer** that runs it: PowerShell 7, Azure CLI and azqr (via winget; Azure CLI is otherwise fetched as a signed installer file from Microsoft and requires administrator approval), Azure Governance Visualizer (fetched as a zip from GitHub) and PowerShell modules (Az.Accounts, Maester, Pester) from the PowerShell Gallery. The versions are pinned to the tested ones, and downloaded zip files are checked against a checksum (SHA256).
2. **Creates sign-in sessions.** They show in the Entra ID sign-in logs and in the Azure activity logs. The script signs out of the sessions it created itself when it is done (unless you choose otherwise).
3. **Maester requires an approval.** The first time, a Global Administrator must approve read permissions for *Microsoft Graph Command Line Tools* (admin consent). That is a change in the tenant. If you skip Maester no approval is needed.
4. **Saves files locally** in the folder you choose, and a zip file of the result.

## Give the SOC / operations security a heads-up

The run generates many read API calls against Azure Resource Manager and Resource Graph, and in some environments responses with `429 Too Many Requests`. The sign-ins come from the computer that runs the script. Please inform your security team in advance so that it is not mistaken for an attack.

## What data ends up in the result

The result describes your environment and is **confidential**:

- structure: management groups, subscriptions, resource groups and resources
- security posture: policies, Secure Score, Defender plans, recommendations
- permissions: **role assignments with names and e-mail addresses**
- cost: monthly cost per subscription for the last 12 months
- Entra ID settings and test results (if Maester is run)

If you want to hide names and e-mail addresses in Governance Visualizer's report: run with `-HidePersonalData`. Note that Maester's report can still contain user names.

## The report and the internet

The report pages that the script creates (`rapport*.html`) are self-contained: style, logo and images are embedded, and they fetch **nothing** from the internet when opened. Links to other pages or tools open in a new window.

The exception is **Azure Governance Visualizer's own report** (the file `AzGovViz_*.html` in the folder `azgovviz\`, which the report links to for more detail). It is not self-contained: when it is opened, the browser fetches its stylesheet, scripts and icons from the internet, among others `www.azadvertizer.net`, `cdnjs.cloudflare.com` and `code.jquery.com`. That means it does not display correctly without internet access, and that these addresses get to see the browser's requests. If you want to avoid that: do not open that file, use the summary on the Governance report page (which is based on the same data) or remove the file before the result is shared.

The look of the report (colours, logo, footer) is set by the files in the folder `branding\`, see `branding\README.md`. The language of the report text is set by `-ReportLanguage` (or `language` in `branding\theme.json`); the messages the script prints in the window are in English.

## How the result is handed over

- The script creates a zip file with an accompanying checksum (`.sha256`) so that the recipient can check that the file has not been changed.
- At the start the script asks whether the zip file should be encrypted. If you answer yes you enter a **password** (at least 12 characters) and the file is encrypted with it (AES-256); if you answer no you get an ordinary zip. The file is called `rapportkit_<tenant>_<period>.zip.rkenc`. Send the file and the password **by different routes** (for example the file by e-mail and the password by SMS or phone). The script does not store the password anywhere.
- The folder with the unencrypted results stays on the computer that ran the script. Delete it when the assignment is done.
- The script does not send any result anywhere by itself.

## How to review the script before running it

1. Read the code in the kit (`Run-Rapportkit.ps1` and the folder `lib\`). It is commented line by line.
2. Check that the kit comes from whoever gave it to you: state the version number (shown at the top when the script starts) and, if you received one, compare the checksum.
3. Preferably run with `-SkipMaester` first, and in a test environment.
4. If the computer has to be completely without internet during the run: ask for the offline package, which contains all the tools.

## Pinned tools and licences

See `THIRD-PARTY-NOTICES.md` for which third-party tools are used, in which versions and under which licences.

## If something goes wrong

The script writes clear error messages and what you should do, and gives a command to run it again. What is already installed is reused. If needed, send `rapportkit.log` from the result folder. It contains no passwords or tokens, but the tenant ID and names of accounts and resources may appear.
