#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Guiderna (Word) har versionsnumret på omslaget. Testet ser till att det följer kitets version, så att en ny version inte
  släpps med gamla guider. Rätta med:  .\docs\Set-GuideVersion.ps1 -Version <version>

  Kör:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:Root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:KitVersion = [regex]::Match((Get-Content (Join-Path $script:Root 'Run-Rapportkit.ps1') -Raw), '\$KitVersion\s*=\s*''([^'']+)''').Groups[1].Value
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Get-GuideVersions([string]$Path) {
        $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $r = New-Object System.IO.StreamReader($z.GetEntry('word/document.xml').Open(), [System.Text.Encoding]::UTF8)
            try { $xml = $r.ReadToEnd() } finally { $r.Dispose() }
            @([regex]::Matches($xml, 'Version (\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value })
        }
        finally { $z.Dispose() }
    }
}

Describe 'Versionen i guiderna' {
    It 'kitets version är läsbar' { $script:KitVersion | Should -Match '^\d+\.\d+\.\d+$' }
    It '<Name> har kitets version på omslaget' -ForEach @(
        @{ Name = 'guide.en.docx'; Rel = 'docs\kund\guide.en.docx' }
        @{ Name = 'guide.sv.docx'; Rel = 'docs\kund\guide.sv.docx' }
        @{ Name = 'Anvandarguide-Azure-Rapportkit.docx'; Rel = 'docs\Anvandarguide-Azure-Rapportkit.docx' }
    ) {
        @(Get-GuideVersions (Join-Path $script:Root $Rel)) | Should -Be @($script:KitVersion) -Because "kör .\docs\Set-GuideVersion.ps1 -Version $($script:KitVersion)"
    }
}
