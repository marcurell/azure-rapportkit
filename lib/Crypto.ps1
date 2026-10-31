<#
  Lösenordskryptering av resultatpaketet (zip) för överlämning.

  Zip-formatet i Windows PowerShell kan inte kryptera, och 7-Zip finns inte på kundens dator. Därför används ett eget,
  enkelt format som bygger på standardfunktioner i .NET (fungerar i både Windows PowerShell 5.1 och PowerShell 7):

    Rubrik:  "RKENC001" (8 byte) + salt (16) + antal PBKDF2-varv (4, little endian) + IV (16)
    Innehåll: AES-256-CBC av zip-filen
    Slut:    HMAC-SHA256 (32) över rubrik + innehåll (encrypt-then-MAC)

  Nycklarna (32 byte för kryptering, 32 för HMAC) härleds ur lösenordet med PBKDF2-HMAC-SHA256. HMAC:en kontrolleras
  innan något dekrypteras, så fel lösenord eller en ändrad fil ger ett tydligt fel i stället för skräp.
  Filerna packas upp med Unprotect-Rapportkit.ps1.

  Obs: formatet är eget och inte granskat av tredje part. Det använder bara standardprimitiver, men välj ett långt
  lösenord (minst 12 tecken) och skicka det via en annan kanal än filen.
#>

$script:RkMagic = [System.Text.Encoding]::ASCII.GetBytes('RKENC001')
$script:RkIterations = 600000
$script:RkMinPasswordLength = 12

# Gör om en SecureString till vanlig text. Används bara precis när nyckeln ska härledas.
function ConvertFrom-RkSecureString([System.Security.SecureString]$Secure) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Härleder krypteringsnyckel och HMAC-nyckel ur lösenord, salt och antal varv.
function Get-RkKeys([string]$Password, [byte[]]$Salt, [int]$Iterations) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $k = $kdf.GetBytes(64)
        @{ Enc = $k[0..31]; Mac = $k[32..63] }
    }
    finally { $kdf.Dispose() }
}

# Jämför två byte-arrayer utan att avbryta vid första skillnaden.
function Test-RkEqual([byte[]]$A, [byte[]]$B) {
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    $diff -eq 0
}

# Krypterar $Path till $Destination med lösenordet.
function Protect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $plain = ConvertFrom-RkSecureString $Password
    if ($plain.Length -lt $script:RkMinPasswordLength) { throw "Lösenordet är för kort (minst $($script:RkMinPasswordLength) tecken)." }
    $data = [System.IO.File]::ReadAllBytes($Path)
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $keys = Get-RkKeys $plain $salt $script:RkIterations
    $plain = $null
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [byte[]]$keys.Enc
        $aes.GenerateIV()
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($data, 0, $data.Length)
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($script:RkMagic, 0, $script:RkMagic.Length)
        $ms.Write($salt, 0, $salt.Length)
        $iter = [BitConverter]::GetBytes([int]$script:RkIterations)
        $ms.Write($iter, 0, 4)
        $ms.Write($aes.IV, 0, 16)
        $ms.Write($cipher, 0, $cipher.Length)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [byte[]]$keys.Mac)
        try { $tag = $hmac.ComputeHash($ms.ToArray()) } finally { $hmac.Dispose() }
        $ms.Write($tag, 0, $tag.Length)
        [System.IO.File]::WriteAllBytes($Destination, $ms.ToArray())
    }
    finally { $aes.Dispose() }
}

# Dekrypterar $Path till $Destination. Ger ett begripligt fel vid fel lösenord eller ändrad fil.
function Unprotect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $all = [System.IO.File]::ReadAllBytes($Path)
    $headerLen = 8 + 16 + 4 + 16
    if ($all.Length -lt ($headerLen + 16 + 32)) { throw 'Filen är för liten för att vara ett krypterat rapportpaket.' }
    $magic = $all[0..7]
    if (-not (Test-RkEqual ([byte[]]$magic) $script:RkMagic)) { throw 'Filen är inte ett krypterat rapportpaket från Azure Rapportkit (fel filformat).' }
    $salt = [byte[]]$all[8..23]
    $iterations = [BitConverter]::ToInt32($all, 24)
    if ($iterations -lt 100000 -or $iterations -gt 5000000) { throw 'Filens rubrik ser ogiltig ut.' }
    $iv = [byte[]]$all[28..43]
    $tag = [byte[]]$all[($all.Length - 32)..($all.Length - 1)]
    $signed = New-Object byte[] ($all.Length - 32)
    [Array]::Copy($all, $signed, $signed.Length)
    $keys = Get-RkKeys (ConvertFrom-RkSecureString $Password) $salt $iterations
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [byte[]]$keys.Mac)
    try { $calc = $hmac.ComputeHash($signed) } finally { $hmac.Dispose() }
    if (-not (Test-RkEqual $calc $tag)) { throw 'Fel lösenord, eller så har filen ändrats eller skadats.' }
    $cipher = New-Object byte[] ($signed.Length - $headerLen)
    [Array]::Copy($signed, $headerLen, $cipher, 0, $cipher.Length)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [byte[]]$keys.Enc
        $aes.IV = $iv
        $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    }
    finally { $aes.Dispose() }
    [System.IO.File]::WriteAllBytes($Destination, $plain)
}
