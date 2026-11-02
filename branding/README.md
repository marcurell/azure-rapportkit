# Branding: the look of the report

*Svenska: [README.sv.md](README.sv.md)*

The look of the report is **the files in this folder**. There is no switch and no choice: replace the files and you get a new look.

```
branding\
  theme.json       <- colours, fonts, logo, footer, report language (Moln på svenska is included)
  logo.svg         <- optional: a logo as an image file (otherwise a wordmark of the text in theme.json)
  logo-dark.svg    <- optional: logo for dark mode
  background.jpg   <- optional: background image
  custom.css       <- optional: your own CSS rules, added last
```

## How to make a customer version with another profile

1. Make a folder with your profile (copy `..\branding-exempel\neutral\theme.json` as a starting point, change it and add a logo).
2. Run `.\Pack-Kit.ps1 -Branding D:\profiles\customer\branding` (add `-Language sv` for a Swedish report). That gives a zip of the kit where `branding\` is your folder.
3. Give the zip to the customer. The report gets exactly the profile that is in the zip.

If you only want to test the look on an existing run without running the tools again: replace the files in `branding\` and run
`.\Run-Rapportkit.ps1 -ReportOnly -Period <year-month>`.

If `theme.json` is missing or something is invalid, the report falls back on built-in defaults and the script writes a
warning. You never get a broken report.

## theme.json

| Field | Meaning |
|---|---|
| `name` | Name of the theme (shown under "About the run") |
| `reportTitle` | Title of the report in the page header |
| `language` | Language of the report text (`en` or `sv`, a pack in `..\lang\`). `-ReportLanguage` on the script overrides it. Empty = English |
| `logo` | See below |
| `colors.light`, `colors.dark` | Colour palette for light and dark mode (follows the reader's setting). Printing always uses light |
| `colors.status` | Colours for `high`, `medium`, `low` and `ok` (labels and cards) |
| `fonts.body`, `fonts.heading` | Font lists (CSS `font-family`). A font that does not exist on the reader's computer is replaced by the next in the list |
| `footer` | Text in the page footer |
| `contact` | `text` and `url` for a contact link in the footer (leave empty to omit) |
| `background` | `file` (image in the folder, at most 500 KB) and `opacity` (0 to 1, default 0.08). Shown behind the content, not when printing |
| `customCss` | File name of a CSS file in the folder (optional) |

Colours in `colors.*`: `bg`, `surface`, `surfaceAlt`, `border`, `text`, `muted`, `accent` (profile colour), `accentText`
(profile colour for text and links, must be readable against `surface`) and `onAccent` (text on top of the profile colour). Values
can be `#rrggbb`, `rgb(...)`, `hsl(...)` or a colour name.

### Logo

Either a **wordmark** (text in colours), like Moln på svenska:

```json
"logo": { "type": "wordmark", "parts": [ { "text": "Molnpå", "color": "text" }, { "text": "svenska", "color": "accent" } ] }
```

(`color` is `text`, `accent`, `accentText` or `muted`.) Or an **image file** in the folder (svg, png, jpg, gif or
webp, at most 300 KB). It is embedded in every page, so the report is self-contained:

```json
"logo": { "type": "image", "file": "logo.svg", "fileDark": "logo-dark.svg", "alt": "Company name", "height": 36 }
```

`fileDark` is optional: a logo that is shown instead when the reader uses dark mode (for example a white variant).

## Keep in mind

- **Rights:** only use a brand (name, logo, colours) that you have the right to use. A profile for someone
  else's brand, for example a customer's or an employer's, requires their permission. Do not put it in the public repo:
  use `Pack-Kit.ps1` with a folder outside the repo.
- **A profile from an unknown source:** `theme.json` is validated (colours and fonts are checked, and only known colour names are allowed in
  the logo), but `custom.css` is included as it is. Review it before you use a profile you did not write yourself.
- **Fonts:** the report does not embed font files (they would make every page several hundred kB larger). Moln på
  svenska uses Inter, and computers without Inter show the next font in the list (Segoe UI).
