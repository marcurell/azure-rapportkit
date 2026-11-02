<#
  Password encryption of the result package (zip) for handover.

  The zip format in Windows PowerShell cannot encrypt, and 7-Zip is not on the customer's computer. Therefore a simple
  format of our own is used, built on standard .NET functions (works in both Windows PowerShell 5.1 and PowerShell 7):

    Header:  "RKENC001" (8 bytes) + salt (16) + number of PBKDF2 iterations (4, little endian) + IV (16)
    Content: AES-256-CBC of the zip file
    End:     HMAC-SHA256 (32) over header + content (encrypt-then-MAC)

  The keys (32 bytes for encryption, 32 for HMAC) are derived from the password with PBKDF2-HMAC-SHA256. The HMAC is
  checked before anything is decrypted, so a wrong password or a modified file gives a clear error instead of garbage.
  The files are unpacked with Unprotect-Rapportkit.ps1.

  Note: the format is our own and has not been reviewed by a third party. It only uses standard primitives, but choose a long
  password (at least 12 characters) and send it through another channel than the file.
#>

$script:RkMagic = [System.Text.Encoding]::ASCII.GetBytes('RKENC001')
$script:RkIterations = 600000
$script:RkMinPasswordLength = 12

# Turns a SecureString into plain text. Used only right when the key is to be derived.
function ConvertFrom-RkSecureString([System.Security.SecureString]$Secure) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Derives the encryption key and HMAC key from the password, salt and number of iterations.
function Get-RkKeys([string]$Password, [byte[]]$Salt, [int]$Iterations) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $k = $kdf.GetBytes(64)
        @{ Enc = $k[0..31]; Mac = $k[32..63] }
    }
    finally { $kdf.Dispose() }
}

# Compares two byte arrays without stopping at the first difference.
function Test-RkEqual([byte[]]$A, [byte[]]$B) {
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    $diff -eq 0
}

# Encrypts $Path to $Destination with the password.
function Protect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $plain = ConvertFrom-RkSecureString $Password
    if ($plain.Length -lt $script:RkMinPasswordLength) { throw "The password is too short (at least $($script:RkMinPasswordLength) characters)." }
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

# Decrypts $Path to $Destination. Gives an understandable error for a wrong password or a modified file.
function Unprotect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $all = [System.IO.File]::ReadAllBytes($Path)
    $headerLen = 8 + 16 + 4 + 16
    if ($all.Length -lt ($headerLen + 16 + 32)) { throw 'The file is too small to be an encrypted report package.' }
    $magic = $all[0..7]
    if (-not (Test-RkEqual ([byte[]]$magic) $script:RkMagic)) { throw 'The file is not an encrypted report package from Azure Rapportkit (wrong file format).' }
    $salt = [byte[]]$all[8..23]
    $iterations = [BitConverter]::ToInt32($all, 24)
    if ($iterations -lt 100000 -or $iterations -gt 5000000) { throw 'The header of the file looks invalid.' }
    $iv = [byte[]]$all[28..43]
    $tag = [byte[]]$all[($all.Length - 32)..($all.Length - 1)]
    $signed = New-Object byte[] ($all.Length - 32)
    [Array]::Copy($all, $signed, $signed.Length)
    $keys = Get-RkKeys (ConvertFrom-RkSecureString $Password) $salt $iterations
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [byte[]]$keys.Mac)
    try { $calc = $hmac.ComputeHash($signed) } finally { $hmac.Dispose() }
    if (-not (Test-RkEqual $calc $tag)) { throw 'Wrong password, or the file has been modified or damaged.' }
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
