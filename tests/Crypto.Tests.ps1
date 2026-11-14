#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests for the password encryption of the result package (lib\Crypto.ps1) and for Unprotect-Rapportkit.ps1.

  Run:  Invoke-Pester .\tests
#>

BeforeAll {
    function New-TestSecret([string]$Text) { $s = New-Object System.Security.SecureString; foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }; $s }
    . (Join-Path $PSScriptRoot '..\lib\Crypto.ps1')
    $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-crypto-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Dir | Out-Null
    $script:Plain = Join-Path $script:Dir 'in.zip'
    $bytes = New-Object byte[] 100000
    (New-Object System.Random 42).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($script:Plain, $bytes)
    $script:Pw = New-TestSecret 'a-long-password-123'
}
AfterAll { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Password encryption of the result package' {
    It 'can be decrypted back to exactly the same content' {
        $enc = Join-Path $script:Dir 'a.rkenc'; $out = Join-Path $script:Dir 'a.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        Unprotect-RapportkitFile $enc $out $script:Pw
        (Get-FileHash $out).Hash | Should -Be (Get-FileHash $script:Plain).Hash
    }
    It 'holds no plain text and gives different output every time (random salt and IV)' {
        $e1 = Join-Path $script:Dir 'b1.rkenc'; $e2 = Join-Path $script:Dir 'b2.rkenc'
        Protect-RapportkitFile $script:Plain $e1 $script:Pw
        Protect-RapportkitFile $script:Plain $e2 $script:Pw
        (Get-FileHash $e1).Hash | Should -Not -Be (Get-FileHash $e2).Hash
        [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($e1), 0, 8) | Should -Be 'RKENC001'
    }
    It 'rejects a wrong password with a clear error and writes no output file' {
        $enc = Join-Path $script:Dir 'c.rkenc'; $out = Join-Path $script:Dir 'c.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        $bad = New-TestSecret 'another-password-999'
        { Unprotect-RapportkitFile $enc $out $bad } | Should -Throw '*Wrong password*'
        Test-Path $out | Should -BeFalse
    }
    It 'detects a modified file' {
        $enc = Join-Path $script:Dir 'd.rkenc'; $out = Join-Path $script:Dir 'd.out'
        Protect-RapportkitFile $script:Plain $enc $script:Pw
        $b = [System.IO.File]::ReadAllBytes($enc); $b[200] = $b[200] -bxor 1; [System.IO.File]::WriteAllBytes($enc, $b)
        { Unprotect-RapportkitFile $enc $out $script:Pw } | Should -Throw '*modified*'
    }
    It 'rejects files in the wrong format' {
        $x = Join-Path $script:Dir 'e.rkenc'
        [System.IO.File]::WriteAllBytes($x, (New-Object byte[] 200))
        { Unprotect-RapportkitFile $x (Join-Path $script:Dir 'e.out') $script:Pw } | Should -Throw '*file format*'
    }
    It 'rejects a password that is too short when encrypting' {
        $short = New-TestSecret 'short'
        { Protect-RapportkitFile $script:Plain (Join-Path $script:Dir 'f.rkenc') $short } | Should -Throw '*too short*'
    }
    It 'handles files larger than the block it reads at a time, and sizes right at the block boundaries' {
        foreach ($size in 1, 16, 1048575, 1048576, 1048577, 2621440) {
            $plain = Join-Path $script:Dir "s$size.bin"; $enc = "$plain.rkenc"; $out = "$plain.out"
            $bytes = New-Object byte[] $size; (New-Object System.Random $size).NextBytes($bytes); [System.IO.File]::WriteAllBytes($plain, $bytes)
            Protect-RapportkitFile $plain $enc $script:Pw
            Unprotect-RapportkitFile $enc $out $script:Pw
            (Get-FileHash $out).Hash | Should -Be (Get-FileHash $plain).Hash -Because "size $size"
        }
    }
    It 'Unprotect-Rapportkit.ps1 unpacks a zip package in a folder' {
        $src = Join-Path $script:Dir 'src'; New-Item -ItemType Directory $src | Out-Null
        Set-Content (Join-Path $src 'rapport.html') '<html>hello</html>'
        $zip = Join-Path $script:Dir 'p.zip'; Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip
        $enc = Join-Path $script:Dir 'rapportkit_x.zip.rkenc'
        Protect-RapportkitFile $zip $enc $script:Pw
        $dest = Join-Path $script:Dir 'out'
        & (Join-Path $PSScriptRoot '..\Unprotect-Rapportkit.ps1') -Path $enc -Destination $dest -Password $script:Pw
        Get-Content (Join-Path $dest 'rapport.html') -Raw | Should -Match 'hello'
    }
}
