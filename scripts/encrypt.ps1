param(
  [string]$Password,
  [string]$InputFile = ".env",
  [string]$OutputFile = ".env.enc"
)

if (-not $Password) {
  $Password = Read-Host -Prompt "Enter encryption password" -AsSecureString
  $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
}

$plainBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $InputFile))
$salt = [byte[]]::new(16)
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)

$deriveBytes = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, 600000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
$key = $deriveBytes.GetBytes(32)
$iv  = $deriveBytes.GetBytes(16)

$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Key = $key
$aes.IV = $iv
$encryptor = $aes.CreateEncryptor()
$cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
$encryptor.Dispose()
$aes.Dispose()

$output = [byte[]]::new(16 + $cipherBytes.Length)
[Buffer]::BlockCopy($salt, 0, $output, 0, 16)
[Buffer]::BlockCopy($cipherBytes, 0, $output, 16, $cipherBytes.Length)

[System.IO.File]::WriteAllBytes($OutputFile, $output)
Write-Host "Encrypted -> $OutputFile"
