<#
  Password encryption of the result package (zip) for handover.

  The zip format in Windows PowerShell cannot encrypt, and a tool such as 7-Zip cannot be assumed to exist on the computer
  that runs the script. Therefore a simple format of our own is used, built on standard .NET functions (works in both
  Windows PowerShell 5.1 and PowerShell 7):

    Header:  "RKENC001" (8 bytes) + salt (16) + number of PBKDF2 iterations (4, little endian) + IV (16)
    Content: AES-256-CBC of the zip file (PKCS7 padding)
    End:     HMAC-SHA256 (32) over header + content (encrypt-then-MAC)

  The keys (32 bytes for encryption, 32 for HMAC) are derived from the password with PBKDF2-HMAC-SHA256. The HMAC is
  checked before anything is decrypted, so a wrong password or a modified file gives a clear error instead of garbage.
  The files are unpacked with Unprotect-Rapportkit.ps1.

  Both directions work on streams, in blocks of 1 MB, so the memory use does not grow with the size of the package
  (a large environment gives a zip of hundreds of megabytes).

  Note: the format is our own and has not been reviewed by a third party. It only uses standard primitives, but choose a long
  password (at least 12 characters) and send it through another channel than the file.
#>

$script:RkMagic = [System.Text.Encoding]::ASCII.GetBytes('RKENC001')
$script:RkIterations = 600000
$script:RkMinPasswordLength = 12
$script:RkHeaderLength = 8 + 16 + 4 + 16      # magic + salt + iterations + IV
$script:RkTagLength = 32                      # HMAC-SHA256
$script:RkBlockSize = 1MB                     # how much is read at a time

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

# An AES-256-CBC object with the given key (and IV, if one is given; otherwise a new random IV is generated).
function New-RkAes([byte[]]$Key, [byte[]]$IV) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $Key
    if ($IV) { $aes.IV = $IV } else { $aes.GenerateIV() }
    $aes
}

# Reads exactly $Count bytes from the stream (a single Read may return fewer). Throws if the stream ends first.
function Read-RkBytes([System.IO.Stream]$Stream, [int]$Count) {
    $buf = New-Object byte[] $Count
    $read = 0
    while ($read -lt $Count) {
        $n = $Stream.Read($buf, $read, $Count - $read)
        if ($n -le 0) { throw 'The file ended unexpectedly.' }
        $read += $n
    }
    , $buf
}

# Encrypts $Path to $Destination with the password.
function Protect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $plain = ConvertFrom-RkSecureString $Password
    if ($plain.Length -lt $script:RkMinPasswordLength) { throw "The password is too short (at least $($script:RkMinPasswordLength) characters)." }
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $keys = Get-RkKeys $plain $salt $script:RkIterations
    $plain = $null
    $aes = New-RkAes ([byte[]]$keys.Enc)
    try {
        # Header and content. Closing the CryptoStream writes the last (padded) block and closes the file.
        $out = [System.IO.File]::Create($Destination)
        try {
            $out.Write($script:RkMagic, 0, $script:RkMagic.Length)
            $out.Write($salt, 0, $salt.Length)
            $out.Write([BitConverter]::GetBytes([int]$script:RkIterations), 0, 4)
            $out.Write($aes.IV, 0, 16)
            $cs = New-Object System.Security.Cryptography.CryptoStream($out, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
            try {
                $in = [System.IO.File]::OpenRead($Path)
                try { $in.CopyTo($cs, $script:RkBlockSize) } finally { $in.Dispose() }
                $cs.FlushFinalBlock()
            }
            finally { $cs.Dispose() }
        }
        finally { $out.Dispose() }

        # The tag: HMAC over everything written so far, added last.
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [byte[]]$keys.Mac)
        try {
            $written = [System.IO.File]::OpenRead($Destination)
            try { $tag = $hmac.ComputeHash($written) } finally { $written.Dispose() }
        }
        finally { $hmac.Dispose() }
        $append = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try { $append.Write($tag, 0, $tag.Length) } finally { $append.Dispose() }
    }
    catch { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw }
    finally { $aes.Dispose() }
}

# Decrypts $Path to $Destination. Gives an understandable error for a wrong password or a modified file, and writes
# nothing in that case: the tag is checked over the whole file before the first byte is decrypted.
function Unprotect-RapportkitFile([string]$Path, [string]$Destination, [System.Security.SecureString]$Password) {
    $in = [System.IO.File]::OpenRead($Path)
    try {
        if ($in.Length -lt ($script:RkHeaderLength + 16 + $script:RkTagLength)) { throw 'The file is too small to be an encrypted report package.' }
        $header = Read-RkBytes $in $script:RkHeaderLength
        if (-not (Test-RkEqual ([byte[]]$header[0..7]) $script:RkMagic)) { throw 'The file is not an encrypted report package from Azure Rapportkit (wrong file format).' }
        $salt = [byte[]]$header[8..23]
        $iterations = [BitConverter]::ToInt32($header, 24)
        if ($iterations -lt 100000 -or $iterations -gt 5000000) { throw 'The header of the file looks invalid.' }
        $iv = [byte[]]$header[28..43]
        $keys = Get-RkKeys (ConvertFrom-RkSecureString $Password) $salt $iterations

        # Check the tag: HMAC over everything except the last 32 bytes, compared with those bytes.
        $signedLength = [long]($in.Length - $script:RkTagLength)
        $buf = New-Object byte[] $script:RkBlockSize
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [byte[]]$keys.Mac)
        try {
            $in.Position = 0
            $left = $signedLength
            while ($left -gt 0) {
                $n = $in.Read($buf, 0, [int][math]::Min([long]$buf.Length, $left))
                if ($n -le 0) { throw 'The file ended unexpectedly.' }
                [void]$hmac.TransformBlock($buf, 0, $n, $null, 0)
                $left -= $n
            }
            [void]$hmac.TransformFinalBlock($buf, 0, 0)
            $calc = $hmac.Hash
        }
        finally { $hmac.Dispose() }
        $tag = Read-RkBytes $in $script:RkTagLength
        if (-not (Test-RkEqual $calc $tag)) { throw 'Wrong password, or the file has been modified or damaged.' }

        # Decrypt the content (between the header and the tag).
        $aes = New-RkAes ([byte[]]$keys.Enc) $iv
        try {
            $out = [System.IO.File]::Create($Destination)
            try {
                $cs = New-Object System.Security.Cryptography.CryptoStream($out, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
                try {
                    $in.Position = $script:RkHeaderLength
                    $left = [long]($signedLength - $script:RkHeaderLength)
                    while ($left -gt 0) {
                        $n = $in.Read($buf, 0, [int][math]::Min([long]$buf.Length, $left))
                        if ($n -le 0) { throw 'The file ended unexpectedly.' }
                        $cs.Write($buf, 0, $n)
                        $left -= $n
                    }
                    $cs.FlushFinalBlock()
                }
                finally { $cs.Dispose() }
            }
            catch { $out.Dispose(); Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw }
            finally { $out.Dispose() }
        }
        finally { $aes.Dispose() }
    }
    finally { $in.Dispose() }
}
