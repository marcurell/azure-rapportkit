BeforeAll {
    function New-TestSecret([string]$Text) { $s = New-Object System.Security.SecureString; foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }; $s }
    . (Join-Path $PSScriptRoot '..\lib\Crypto.ps1')
    $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-crypto-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Dir | Out-Null
    $script:Plain = Join-Path $script:Dir 'in.zip'
    $bytes = New-Object byte[] 100000
    (New-Object System.Random 42).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($script:Plain, $bytes)
    $script:Pw = New-TestSecret 'ett-langt-losenord-123'
}
AfterAll { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Lösenordskryptering av resultatpaketet' {
    It 'kan dekrypteras tillbaka till exakt samma innehåll' {
        $enc = Join-Path $script:Dir 'a.rkenc'; $out = Join-Path $script:Dir 'a.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        Unprotect-RapportkitFile $enc $out $script:Pw
        (Get-FileHash $out).Hash | Should -Be (Get-FileHash $script:Plain).Hash
    }
    It 'innehåller inte klartext och ger olika utdata varje gång (slumpat salt och IV)' {
        $e1 = Join-Path $script:Dir 'b1.rkenc'; $e2 = Join-Path $script:Dir 'b2.rkenc'
        Protect-RapportkitFile $script:Plain $e1 $script:Pw
        Protect-RapportkitFile $script:Plain $e2 $script:Pw
        (Get-FileHash $e1).Hash | Should -Not -Be (Get-FileHash $e2).Hash
        [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($e1), 0, 8) | Should -Be 'RKENC001'
    }
    It 'avvisar fel lösenord med tydligt fel och skriver ingen utfil' {
        $enc = Join-Path $script:Dir 'c.rkenc'; $out = Join-Path $script:Dir 'c.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        $bad = New-TestSecret 'ett-annat-losenord-999'
        { Unprotect-RapportkitFile $enc $out $bad } | Should -Throw '*Fel lösenord*'
        Test-Path $out | Should -BeFalse
    }
    It 'upptäcker en ändrad fil' {
        $enc = Join-Path $script:Dir 'd.rkenc'; $out = Join-Path $script:Dir 'd.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        $b = [System.IO.File]::ReadAllBytes($enc); $b[200] = $b[200] -bxor 1; [System.IO.File]::WriteAllBytes($enc, $b)
        { Unprotect-RapportkitFile $enc $out $script:Pw } | Should -Throw '*ändrats*'
    }
    It 'avvisar filer i fel format' {
        $x = Join-Path $script:Dir 'e.rkenc'
        [System.IO.File]::WriteAllBytes($x, (New-Object byte[] 200))
        { Unprotect-RapportkitFile $x (Join-Path $script:Dir 'e.out') $script:Pw } | Should -Throw '*filformat*'
    }
    It 'avvisar för kort lösenord vid kryptering' {
        $short = New-TestSecret 'kort'
        { Protect-RapportkitFile $script:Plain (Join-Path $script:Dir 'f.rkenc') $short } | Should -Throw '*för kort*'
    }
    It 'Unprotect-Rapportkit.ps1 packar upp ett zip-paket i en mapp' {
        $src = Join-Path $script:Dir 'src'; New-Item -ItemType Directory $src | Out-Null
        Set-Content (Join-Path $src 'rapport.html') '<html>hej</html>'
        $zip = Join-Path $script:Dir 'p.zip'; Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip
        $enc = Join-Path $script:Dir 'rapportkit_x.zip.rkenc'
        Protect-RapportkitFile $zip $enc $script:Pw
        $dest = Join-Path $script:Dir 'ut'
        & (Join-Path $PSScriptRoot '..\Unprotect-Rapportkit.ps1') -Path $enc -Destination $dest -Password $script:Pw
        Get-Content (Join-Path $dest 'rapport.html') -Raw | Should -Match 'hej'
    }
}
