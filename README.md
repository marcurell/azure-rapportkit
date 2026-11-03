# azure-rapportkit

[![CI](https://github.com/marcurell/azure-rapportkit/actions/workflows/ci.yml/badge.svg)](https://github.com/marcurell/azure-rapportkit/actions/workflows/ci.yml)

*Svenska: [README.sv.md](README.sv.md)*

A PowerShell script that produces the material for an Azure review. It fetches the tools, signs in, runs three free read-only tools and summarises the result in an HTML report. The script's messages are in English; the **report** can be produced in English or Swedish (see [Report language](#report-language)).

| Tool | What it gives |
|---|---|
| [Azure Governance Visualizer](https://github.com/Azure/Azure-Governance-Visualizer) | Management groups, policies, role assignments |
| [azqr](https://github.com/Azure/azqr) | Recommendations per resource, Advisor, Defender |
| [Maester](https://maester.dev) (optional) | Tests of Entra ID: MFA, Conditional Access, privileged roles |

The script **writes nothing to Azure resources or to the Entra configuration**. It does, however, do the following, which is good to know: it installs tools on the computer, creates sign-in sessions (which show in the tenant's logs), requires an administrator to approve read permissions for Maester (admin consent, a change in the tenant), and saves confidential results locally. All of this is described for the customer in [docs/KUNDINFO.en.md](docs/KUNDINFO.en.md). The tools and their licences are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Step by step for whoever runs the tool: [User guide (Word)](docs/Anvandarguide-Azure-Rapportkit.docx) (Swedish).

## Quick start: one command

Open PowerShell or PowerShell ISE and paste the block below. It downloads the code from the latest release (without git), unpacks it, unblocks the files and starts the script in a new PowerShell window. Follow the instructions in that window.

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dest = Join-Path $env:USERPROFILE 'rapportkit-kit'
$zip  = Join-Path $env:TEMP 'azure-rapportkit.zip'
New-Item -ItemType Directory -Force $dest | Out-Null
Invoke-WebRequest 'https://github.com/marcurell/azure-rapportkit/archive/refs/tags/v1.4.4.zip' -OutFile $zip
Expand-Archive $zip $dest -Force
Get-ChildItem $dest -Recurse | Unblock-File
$script = Join-Path $dest 'azure-rapportkit-1.4.4\Run-Rapportkit.ps1'
$arg = '-NoExit -ExecutionPolicy Bypass -File "' + $script + '"'
Start-Process powershell -ArgumentList $arg
```

Why a new window: PowerShell ISE cannot handle the sign-in windows and prompts from PowerShell 7, so the script should not be run directly in ISE.

Have the tenant ID at hand (Entra ID > Overview > Tenant ID). The script asks for it, and then two sign-in windows open in the browser.

## Customer version (a zip that is e-mailed)

Customers are not sent the link to this repo but a ready-made zip with the customer's own README and guide (`docs\kund\`), the wanted branding and the wanted report language:

```powershell
.\Pack-Kit.ps1 -Branding D:\profiles\customer\branding -Language sv    # without -Branding the kit's own branding\ is used
```

The zip contains nothing that points to the repo. The customer unpacks it, unblocks it and runs `Run-Rapportkit.ps1`, and sends back the encrypted result package (`.rkenc`) and the password by separate routes. You unpack it with `Unprotect-Rapportkit.ps1`. The offline package (`Build-Bundle.ps1`) contains the same customer documents. `-Language` sets the language of the report text and picks the customer README, `KUNDINFO` and guide in that language.

## Download manually

If you do not want to use the command above: go to **Releases** in this repo and download `Source code (zip)` for the latest version.

1. Save the zip, right-click it, choose **Properties**, tick **Unblock** and click OK. (Windows otherwise blocks scripts downloaded from the internet.)
2. Right-click the zip and choose **Extract All**.
3. Continue with "Run the script" below.

If you prefer git: `git clone https://github.com/marcurell/azure-rapportkit.git`

## Run the script

Open an ordinary PowerShell window (not ISE) in the folder with the script. Windows PowerShell 5.1 is enough: the script installs PowerShell 7 and restarts itself there. Run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-Rapportkit.ps1
```

During the run the script shows a box per step (`STEP 3 OF 10`) with a progress bar, coloured status labels (`OK`, `WARNING`, `MISSING`, `FAILED`) and `TODO` when something is yours to do. It ends with a summary box with time per tool. If the frames look wrong in your console: run with `-Plain`. Questions are answered with `y` or `n` (`j` and `ja` also count as yes).

The script first asks **where the result should be saved** (suggestion: `%USERPROFILE%\rapportkit`). It warns if the folder is in OneDrive (syncs to the cloud) or under Documents/Desktop (Windows may block writing). Give `-OutputRoot <folder>` to skip the question.

## Report language

The report text is in English (`en`) or Swedish (`sv`). The script's own messages in the window are always in English. The language is chosen, in this order, by:

1. `-ReportLanguage <code>` on `Run-Rapportkit.ps1` (`-ReportLanguage sv`),
2. `"language"` in `branding\theme.json` (what `Pack-Kit.ps1 -Language sv` writes in the customer zip),
3. otherwise English.

The texts are in language packs: `lang\en.psd1` (the base, every key must exist there) and `lang\sv.psd1`. A key that is missing in a translation falls back to English. To add a language: copy `lang\en.psd1` to `lang\<code>.psd1`, translate the values (keep the placeholders `{0}`, `{1}` and keys ending in `.html` as HTML) and run `-ReportLanguage <code>`. The tests check that every pack has the same keys and placeholders as `en.psd1`. Rebuild an older run in another language without running the tools again: `.\Run-Rapportkit.ps1 -ReportOnly -Period 2026-10 -ReportLanguage sv`.

## Results and logs

Everything ends up in `<result folder>\<year-month>\`:

| File | Content |
|---|---|
| `rapport.html` (+ six pages) | The report in one common style: **Overview**, **Structure** (management groups, subscriptions, virtual networks and peerings), **Governance**, **Resources**, **Entra ID**, **Defender & cost** and **About the run**. Every page is self-contained (style and logo are embedded) and fetches nothing from the internet |
| `azgovviz\`, `azqr\`, `maester\` | The tools' own reports |
| `portal\` | Defender and cost data as CSV (including Secure Score per control) |
| `struktur\` | Management groups, virtual networks, peerings and network nodes as CSV |
| `rapportkit.log` | Clean log with timestamp and level |
| `rapportkit-console.log` | The whole console output including the tools' text (troubleshooting; not included in the zip) |
| `run-summary.json` | Machine-readable summary: versions, time per step, status, warnings, exit code |

(The CSV files keep Swedish column names and file names: they are a data format shared with older runs.)

Outside the folder: `rapportkit_<tenant>_<year-month>.zip.rkenc` with a `.sha256` file, so that the recipient can check that the file arrived unchanged (turn off with `-NoZip`). Encryption is **optional**: the script asks at the start whether the package should be encrypted, and if you answer yes the file is **password-encrypted** (AES-256) with a password you enter (at least 12 characters, confirmed twice). If you answer no (or use `-NoEncrypt`) you get an ordinary `.zip`. Whoever runs it sends the file and the password by **different routes** (for example the file by e-mail and the password by SMS). The recipient unpacks with `Unprotect-Rapportkit.ps1` (see below). The folder with unencrypted results stays on the customer's computer and should be deleted when the assignment is done. `-NoEncrypt` gives an ordinary zip (only if the result does not leave the computer).

### Unpack an encrypted package

```powershell
.\Unprotect-Rapportkit.ps1 -Path C:\Temp\rapportkit_00000000_2026-10.zip.rkenc
```

The script checks the `.sha256` file if it is next to the package, asks for the password and unpacks in a folder next to the file. A wrong password or a modified file gives a clear error. The format is our own, but built only on standard .NET functions: PBKDF2-HMAC-SHA256 (600,000 iterations) for the keys, AES-256-CBC and HMAC-SHA256 (encrypt-then-MAC). It has not been reviewed by a third party: choose a long password.

**Sign-out:** the script signs out of the sessions (Azure CLI, Azure PowerShell, Microsoft Graph) that it created itself when it is done. A sign-in that existed before is not touched. Turn off with `-KeepLogin`.

## Look (branding)

The report is a multi-page website in one common style, with navigation, light and dark mode (follows the reader's setting) and a print mode. The button "Save the whole report as PDF" opens a combination of all the pages (`rapport-komplett.html`) and shows the print dialog.

The look is **the files in the folder `branding\`** (`theme.json`, logo, background, `custom.css`). There is no switch: replace the files and you get a new look. The default is Moln på svenska. For a customer version with another profile you make a zip with `Pack-Kit.ps1`:

```powershell
.\Pack-Kit.ps1 -Branding D:\profiles\customer\branding     # zip of the kit with your branding\ instead
.\Run-Rapportkit.ps1 -ReportOnly -Period 2026-10             # rebuild the report from existing results, without running the tools
```

See [branding/README.md](branding/README.md) for the files and the fields in `theme.json`. If something is missing or invalid, built-in defaults are used and the script warns. An example of another profile is in `branding-exempel\neutral`.

**The tools' own reports** (Governance Visualizer, Maester, azqr's Excel) cannot be restyled, so they are linked as further reading and open in a new window. Note that Governance Visualizer's own report fetches its style, scripts and icons from the internet (among others `www.azadvertizer.net` and `cdnjs.cloudflare.com`), and therefore does not display correctly offline. The pages in this kit make no external calls.

## Anonymized report

The script asks at the start: "Do you also want to create an anonymized version of the report?" (or use `-Anonymize`; `-Yes` means no). A second set of pages is then built in `anonym\` next to the ordinary report, meant for demos, training or sharing:

- users, groups, service principals, subscriptions, management groups, resource groups and resources are replaced by aliases such as "User 3" and "Subscription 1" (the same name always gets the same alias),
- all GUIDs, e-mail addresses and `*.onmicrosoft.com` addresses are replaced, also ones that were not collected,
- computer, account and paths on the About page are hidden,
- links to the tools' own reports are removed (they contain real names).

**Limitation:** free text outside the collected columns (custom policy names, tag values, names shorter than 4 characters) is not replaced. Read through the anonymous version before it is shared. There is no key that links aliases to real names; run the report again if you need to look something up. The raw data in `azgovviz\`, `azqr\`, `maester\` and `portal\` is not anonymized, and the anonymous folder is part of the encrypted package as usual. So share only the folder `anonym\`.

Rebuild an anonymous version of an old run without running the tools again: `.\Run-Rapportkit.ps1 -ReportOnly -Anonymize -Period 2026-10`.

## Permissions

The account that signs in needs:

| Role | Scope | Needed for |
|---|---|---|
| Reader | Tenant Root Group | Governance Visualizer, azqr |
| Security Reader | Tenant Root Group | Defender recommendations and Secure Score |
| Cost Management Reader | Tenant Root Group | Cost for the last 12 months |
| Global Reader | Microsoft Entra ID | Maester |

**The roles are checked right after sign-in (step 3), before anything more is fetched.** If a role is missing the script shows which commands add it and asks whether you want to continue anyway. The default answer is no, and the run then ends with the instruction. Global Administrator in Entra ID does not automatically give Azure roles: see the section "Give yourself read access at tenant root" below.

If the account only has access to one subscription Governance Visualizer fails the permission check, because the tool must be able to read the management group at tenant root. The other steps run anyway.

**About the Reader role:** Governance Visualizer only checks that the management group can be read, so which role gives the read access does not matter (even User Access Administrator is technically enough). Reader is recommended because it gives the least privilege. If the account has more roles than Reader the tool writes a "least privilege" recommendation; the script does not let it pause the run. The role **Management Group Reader** is something other than **Reader**: it only gives read access to the group structure, not to the resources.

**Check the scope:** the roles should be on the **Tenant Root Group** (Management groups > Tenant Root Group > Access control (IAM) > Role assignments), not on a subscription or resource group.

## Steps

1. **Preparation**: tenant ID, result folders, log file.
2. **Pre-flight**: checks tools, network (GitHub, PowerShell Gallery, sign-in, Azure, Graph), disk space and whether questions can be answered, before anything is fetched. If something is missing it is shown clearly and you choose whether to continue anyway.
3. **Azure CLI, sign-in and role check**: installs Azure CLI if it is missing, signs in and checks the roles of the account (Azure and Entra). If roles are missing you get the instruction and choose to stop or continue.
4. **Dependencies**: fetches what is missing, in **pinned, tested versions**. PowerShell 7 and azqr via winget (azqr otherwise directly from GitHub), Azure CLI via winget or, if winget is missing, as a signed installer file (MSI) directly from Microsoft (requires administrator approval), Governance Visualizer as a zip from GitHub and modules from the PowerShell Gallery to `<result folder>\_modules`. The zip files are checked against SHA256 checksums, and a changed file stops the run (see `-AllowUnverified`).
5. **Sign-in**: Az PowerShell and optionally Microsoft Graph. Then it is checked whether the account can read the management group that Governance Visualizer starts at.
6. **Governance Visualizer**
7. **azqr**
8. **Maester**
9. **Defender, cost and structure**: also fetches the management group tree and the network (virtual networks, peerings, firewalls and gateways) via Azure Resource Graph, read-only, for the Structure report page. Defender and cost: automatically fetches Defender plans, Secure Score (also per control), Defender recommendations and cost per month for the last 12 months, via Azure Resource Manager (read-only). Saved as CSV in `portal\`. What used to be manual exports from the portal.
10. **HTML report**

## Switches

| Switch | Meaning |
|---|---|
| `-TenantId <guid>` | Skips the tenant question |
| `-ManagementGroupId <id>` | Runs Governance Visualizer against another management group than tenant root |
| `-SkipGovViz` / `-SkipAzqr` / `-SkipMaester` / `-SkipPortal` | Skip a tool (`-SkipPortal` = Defender, cost and structure) |
| `-DeviceLogin` | Sign in with a code instead of a browser window |
| `-NoInstall` | Fetch and install nothing |
| `-Offline` | Download nothing, use only `tools\` (see below) |
| `-ReportOnly` | Only rebuild the HTML report from existing results |
| `-ReportLanguage <code>` | Language of the report text (`en`, `sv`); default: `language` in `branding\theme.json`, else `en` |
| `-Yes` | Answer yes to all "continue anyway?" questions (for automated runs) |
| `-MaxPortalSubscriptions <n>` | At most this many active subscriptions are queried for Defender and cost data (default 25) |
| `-OutputRoot <folder>` | Result folder. If it is not given the script asks |
| `-Period <name>` | Name of the subfolder for the run (default: the current month, `yyyy-MM`) |
| `-Anonymize` | Also build an anonymized version of the report in `anonym\` (names, e-mail and IDs are replaced by aliases). Without the switch the script asks at the start |
| `-HidePersonalData` | Hide names and e-mail addresses in Governance Visualizer's report (Maester's report can still contain names) |
| `-KeepLogin` | Do not sign out of sessions that the script created |
| `-NoZip` | Do not create a zip of the result |
| `-NoEncrypt` | Do not encrypt the zip file (by default it is encrypted with a password you enter at the start) |
| `-ZipPassword <SecureString>` | Password for the zip file in automated runs (PowerShell 7) |
| `-Plain` | Draw frames with ASCII characters (for consoles that show special characters wrongly) |
| `-LatestTools` | Use the latest tool versions instead of the tested ones, and skip checksums |
| `-AllowUnverified` | Continue even if a checksum does not match. Use only after your own check |

## Offline bundle

If the customer's computer cannot fetch things itself: run `Build-Bundle.ps1` on a computer with internet. It downloads the pinned versions to `tools\` (the checksums are checked), and packs the script, the tools, the licence texts and the customer information in `rapportkit-bundle.zip` with a `.sha256` file. The customer unpacks the zip and runs `.\Run-Rapportkit.ps1 -Offline`.

```powershell
.\Build-Bundle.ps1                  # with installers (~300 MB)
.\Build-Bundle.ps1 -SkipInstallers  # without PowerShell/Azure CLI/Git
```

### Give yourself read access at tenant root (done by a Global Administrator)

1. Entra ID > Properties > **Access management for Azure resources** = Yes > Save. (Temporarily gives the User Access Administrator role at scope `/`.) Sign out and in again.
2. Run, with an account that now has the right:

```powershell
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Reader" --scope "/"
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Security Reader" --scope "/"
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Cost Management Reader" --scope "/"
```

3. Set **Access management for Azure resources** back to No.

## If something goes wrong

The script is built so that interruptions are understandable:

- **A tool fails:** the others run anyway. The error and what to do about it show in the summary in the console and in the status table at the top of `rapport.html`.
- **The script cannot continue** (for example no sign-in or no internet access): it writes the cause, what you should do and exactly which command to run again. What is already installed is reused.
- **You stop (Ctrl+C) or close the window:** just run the script again. Nothing has been changed in Azure.
- **Downloads are checked:** file size, that zip files are intact and that expected files exist. Failed downloads are retried 3 times.
- **Result files are checked** before the report is built. An unexpected format is shown as a warning in the report instead of stopping it.

Exit code: `0` = everything went well, `2` = a tool failed but a report exists, `1` = the run was aborted.

## Troubleshooting

| Problem | Action |
|---|---|
| `AuthorizationFailed` or empty results | Check that the roles are active (PIM) and assigned at the right scope |
| Governance Visualizer: permission check FAILED, even though you are Global Administrator | Global Administrator in Entra ID does **not** give access to Azure resources. Elevate access temporarily: Entra ID > Properties > **Access management for Azure resources** = Yes. Then assign yourself Reader (and Security Reader, Cost Management Reader) at scope `/`, and set the toggle back to No. Commands are in the section above |
| Windows Defender: "Unauthorized changes blocked" for `pwsh.exe` | Controlled folder access (ransomware protection) blocks writing to a protected folder. The notification names the folder: open Windows Security > Virus & threat protection > Ransomware protection > Block history. Let the script write to a folder that is not protected (`-OutputRoot C:\rapportkit`) or allow `C:\Program Files\PowerShell\7\pwsh.exe` under "Allow an app through Controlled folder access". If IT manages the security setting they have to do it |
| Governance Visualizer: `check FAILED` | The account cannot read the management group. Assign Reader on the **Tenant Root Group** (check the scope), or give `-ManagementGroupId` |
| Governance Visualizer shows "LEAST PRIVILEGE ADVICE" | Information message: the account has more roles than Reader. Not an error; the script does not let it pause the run |
| Governance Visualizer stops on `classicAdministrators` (404) | Fixed: the retired API is skipped in the local copy (classic administrators are therefore not reported) |
| `Connect-Maester` requires approval | A Global Administrator must give admin consent for Microsoft Graph Command Line Tools |
| Script is blocked | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` in the same window. If the execution policy is controlled by group policy Bypass does not apply; the pre-flight shows it |
| Sign-in fails with `AADSTS53003`, `AADSTS50076` etc. | The tenant's Conditional Access stops the sign-in. Ask IT to allow the apps "Microsoft Azure CLI", "Azure PowerShell" and "Microsoft Graph Command Line Tools" for your account, or run from a managed/compliant computer |
| The roles are "missing" although you have them via PIM | Activate the roles first (Entra ID > Privileged Identity Management > My roles) and run again |
| Downloads fail behind a corporate proxy | The script sends the Windows sign-in to the proxy. If that does not help: check that github.com, objects.githubusercontent.com and www.powershellgallery.com are let through, or use the offline bundle (`Build-Bundle.ps1`) |
| The pre-flight says "constrained mode" (AppLocker/WDAC) | The script cannot run in Constrained Language Mode. Ask IT for an exception, or run on another computer |
| `azqr cannot be run` | Antivirus/EDR/AppLocker blocks the downloaded `azqr.exe`. Ask IT to allow it |

Send `rapportkit.log` (and if needed `rapportkit-console.log`) from the result folder when you ask for help. The logs contain no passwords or tokens, but the tenant ID and names of accounts and resources may appear.

## Licence

MIT, see [LICENSE](LICENSE). The tools that the script fetches have their own licences, see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Known

- Governance Visualizer is fetched in a pinned version (6.7.2) that the script is tested against.
- The script patches the fetched copy of Governance Visualizer (the one in `<result folder>\Azure-Governance-Visualizer-6.7.2`, the original on GitHub is not touched) in three places: no y/n question about modules, no pauses for a key press, and the retired classic administrators API is skipped. The patches are tied to version 6.7.2 and can stop working if the tool changes; the script warns if a patch could not be applied.
- Governance Visualizer is run with `-NoPIMEligibility` (requires a service account) and `-NoALZPolicyVersionChecker` (requires git and GitHub).
- The result folders contain confidential information. They are outside the repo and must never be checked in.
- Defender recommendations are fetched from Azure's API, which can return an incomplete list. That is why Secure Score per control is also fetched, and the script warns when they do not match.
- Development: `tests\` contains unit tests (Pester) and `.github\workflows\ci.yml` runs a syntax check in PowerShell 5.1 and 7, static analysis, the tests, and a weekly check that the pinned checksums still match upstream. The tests also check that every language pack in `lang\` has the same keys and placeholders.
