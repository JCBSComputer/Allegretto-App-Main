param(
  [string]$Password,
  [string]$InputFile = ".env.enc",
  [string]$OutputFile = ".env"
)

if (-not (Test-Path $InputFile)) {
  Write-Error "File not found: $InputFile"
  exit 1
}

if (-not $Password) {
  $Password = Read-Host -Prompt "Enter decryption password" -AsSecureString
  $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
}

$encBytes = [System.IO.File]::ReadAllBytes($InputFile)
$salt = $encBytes[0..15]
$cipherBytes = $encBytes[16..($encBytes.Length - 1)]

$deriveBytes = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, 600000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
$key = $deriveBytes.GetBytes(32)
$iv  = $deriveBytes.GetBytes(16)

try {
  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Key = $key
  $aes.IV = $iv
  $decryptor = $aes.CreateDecryptor()
  $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
  $decryptor.Dispose()
  $aes.Dispose()
  [System.IO.File]::WriteAllBytes($OutputFile, $plainBytes)
  Write-Host "Decrypted -> $OutputFile"
}
catch {
  Write-Error "Decryption failed. Wrong password or corrupted file."
  exit 1
}
