# =====================================================================
#  사진 앨범 추가 스크립트  (add-photo-album.ps1)
#
#  사용법: 사진들이 들어있는 폴더(또는 사진 파일 여러 개)를
#          "사진앨범추가.bat" 파일 위로 드래그하세요.
#
#  하는 일:
#   1) 날짜 / 제목 / 설명 입력 받기
#   2) 사진을 content/assets/photos/ 로 복사하면서
#      - 가로/세로 1920px 이하로 축소
#      - JPEG 품질 85로 재압축
#      - 휴대폰 사진 회전정보(EXIF) 반영
#   3) content/photos.json 맨 앞에 새 앨범 추가
#   4) git commit + push  ->  Netlify 자동 배포
# =====================================================================

[CmdletBinding()]
param(
  [string]$Date,
  [string]$Title,
  [string]$Desc,
  [switch]$NoGit,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Paths
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Add-Type -AssemblyName System.Drawing

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PhotosDir  = Join-Path $RepoRoot "content\assets\photos"
$JsonPath   = Join-Path $RepoRoot "content\photos.json"
$MaxDim     = 1920
$Quality    = 85

function Fail($msg) {
  Write-Host ""
  Write-Host "  [오류] $msg" -ForegroundColor Red
  Write-Host ""
  exit 1
}

Write-Host ""
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host "   사진 앨범 추가" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan

# ---- 0) 입력 파일 수집 ----------------------------------------------
if (-not $Paths -or $Paths.Count -eq 0) {
  Fail "사진 폴더나 파일을 이 스크립트(사진앨범추가.bat) 위로 드래그해 주세요."
}

$imgExt = @(".jpg",".jpeg",".png",".webp",".bmp",".heic")
$srcFiles = @()
foreach ($p in $Paths) {
  if (Test-Path $p -PathType Container) {
    $srcFiles += Get-ChildItem -LiteralPath $p -File | Where-Object { $imgExt -contains $_.Extension.ToLower() }
  } elseif (Test-Path $p -PathType Leaf) {
    $f = Get-Item -LiteralPath $p
    if ($imgExt -contains $f.Extension.ToLower()) { $srcFiles += $f }
  }
}
$srcFiles = $srcFiles | Sort-Object Name
if ($srcFiles.Count -eq 0) { Fail "이미지 파일을 찾지 못했습니다. (jpg/png/webp)" }

Write-Host ""
Write-Host "  사진 $($srcFiles.Count)장을 찾았습니다." -ForegroundColor Cyan
Write-Host ""

# ---- 1) 메타데이터 입력 --------------------------------------------
$today = (Get-Date).ToString("yyyy.MM.dd")
$date = $Date
if ([string]::IsNullOrWhiteSpace($date)) { $date = Read-Host "  날짜 (YYYY.MM.DD, 그냥 엔터 = $today)" }
if ([string]::IsNullOrWhiteSpace($date)) { $date = $today }
$date = $date.Trim().Replace("-", ".").Replace("/", ".")
if ($date -notmatch '^\d{4}\.\d{2}\.\d{2}$') { Fail "날짜 형식이 올바르지 않습니다: $date  (예: 2026.03.14)" }

$title = $Title
if ([string]::IsNullOrWhiteSpace($title)) { $title = Read-Host "  제목" }
if ([string]::IsNullOrWhiteSpace($title)) { Fail "제목은 필수입니다." }
$title = $title.Trim()

$desc = $Desc
if ($null -eq $desc) { $desc = Read-Host "  설명 (선택, 없으면 엔터)" }
$desc = "$desc".Trim()

# ---- 2) 파일명 접두사 / 시작 번호 ---------------------------------
$prefix = $date.Replace(".", "")            # 20260314
$existing = @(Get-ChildItem -LiteralPath $PhotosDir -File -Filter "$prefix*" -ErrorAction SilentlyContinue)
$startN = 0
foreach ($e in $existing) {
  if ($e.BaseName -match "^${prefix}_(\d+)$") { $n = [int]$Matches[1]; if ($n -gt $startN) { $startN = $n } }
}

# ---- 3) 이미지 변환 + 복사 ----------------------------------------
$jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }

function Get-OrientationRotate($img) {
  try {
    if ($img.PropertyIdList -contains 0x0112) {
      $o = [BitConverter]::ToUInt16($img.GetPropertyItem(0x0112).Value, 0)
      switch ($o) {
        3 { return [System.Drawing.RotateFlipType]::Rotate180FlipNone }
        6 { return [System.Drawing.RotateFlipType]::Rotate90FlipNone }
        8 { return [System.Drawing.RotateFlipType]::Rotate270FlipNone }
      }
    }
  } catch {}
  return [System.Drawing.RotateFlipType]::RotateNoneFlipNone
}

$newPaths = @()
$i = $startN
foreach ($src in $srcFiles) {
  $i++
  $outName = "{0}_{1:D2}.jpg" -f $prefix, $i
  $outPath = Join-Path $PhotosDir $outName

  try {
    $img = [System.Drawing.Image]::FromFile($src.FullName)
  } catch {
    Write-Host "    ! 건너뜀 (열 수 없음): $($src.Name)" -ForegroundColor Yellow
    $i--
    continue
  }

  $rot = Get-OrientationRotate $img
  if ($rot -ne [System.Drawing.RotateFlipType]::RotateNoneFlipNone) { $img.RotateFlip($rot) }

  $w = $img.Width; $h = $img.Height
  $scale = 1.0
  $long = [Math]::Max($w, $h)
  if ($long -gt $MaxDim) { $scale = $MaxDim / $long }
  $nw = [Math]::Max(1, [int][Math]::Round($w * $scale))
  $nh = [Math]::Max(1, [int][Math]::Round($h * $scale))

  $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($img, 0, 0, $nw, $nh)
  $g.Dispose()
  $img.Dispose()

  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
  $bmp.Save($outPath, $jpegEncoder, $ep)
  $bmp.Dispose()

  $kb = [int]((Get-Item $outPath).Length / 1KB)
  Write-Host ("    + {0}  ({1}x{2}, {3} KB)" -f $outName, $nw, $nh, $kb) -ForegroundColor DarkGray
  $newPaths += "/content/assets/photos/$outName"
}

if ($newPaths.Count -eq 0) { Fail "변환된 이미지가 없습니다." }

# ---- 4) photos.json 에 앨범 추가 ---------------------------------
if (-not (Test-Path $JsonPath)) { Fail "photos.json 을 찾을 수 없습니다: $JsonPath" }
$json = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8

# JSON 문자열 이스케이프 (제목/설명에 " 나 \ 가 있을 수 있음)
function Esc($s) { return ($s -replace '\\','\\' -replace '"','\"' -replace "`r","" -replace "`n",'\n') }

$imgLines = ($newPaths | ForEach-Object { '        "' + $_ + '"' }) -join ",`n"

$descLine = ""
if (-not [string]::IsNullOrWhiteSpace($desc)) { $descLine = '      "desc": "' + (Esc $desc) + '",' + "`n" }

$albumObj = @"
    {
      "date": "$date",
      "title": "$(Esc $title)",
$descLine      "images": [
$imgLines
      ]
    }
"@

if ($json -match '(?s)("albums"\s*:\s*\[)\s*\{') {
  # 기존 앨범이 있음 -> 맨 앞에 삽입하고 콤마로 이어줌
  $json = $json -replace '(?s)("albums"\s*:\s*\[)\s*\{', "`$1`n$albumObj,`n    {"
}
elseif ($json -match '(?s)("albums"\s*:\s*\[)\s*\]') {
  # 앨범이 하나도 없음
  $json = $json -replace '(?s)("albums"\s*:\s*\[)\s*\]', "`$1`n$albumObj`n  ]"
}
else {
  Fail "photos.json 형식을 인식하지 못했습니다. (`"albums`": [ 를 찾을 수 없음)"
}

# 유효성 검사
try { $json | ConvertFrom-Json | Out-Null }
catch { Fail "생성된 JSON 이 유효하지 않습니다. 변경을 취소합니다. ($($_.Exception.Message))" }

[System.IO.File]::WriteAllText($JsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "  photos.json 업데이트 완료 ($($newPaths.Count)장)" -ForegroundColor Green

# ---- 5) git commit + push --------------------------------------
if ($NoGit) {
  Write-Host ""
  Write-Host "  (-NoGit) git 단계를 건너뜁니다. photos.json 과 이미지가 로컬에 저장됐습니다." -ForegroundColor Yellow
  exit 0
}
$git = (Get-Command git -ErrorAction SilentlyContinue)
if (-not $git) {
  Write-Host ""
  Write-Host "  [주의] git 이 설치되어 있지 않아 자동 업로드를 못 했습니다." -ForegroundColor Yellow
  Write-Host "         파일은 로컬에 저장됐습니다. 수동으로 커밋/푸시하거나 저에게 알려주세요." -ForegroundColor Yellow
  exit 0
}

Push-Location $RepoRoot
try {
  Write-Host ""
  Write-Host "  원격 변경사항 동기화 중..." -ForegroundColor Cyan
  git fetch origin --quiet
  git pull --rebase --autostash origin main
  if ($LASTEXITCODE -ne 0) { throw "git pull 실패 (충돌 가능). 수동 확인이 필요합니다." }

  git add -A
  git commit -m "Add photo album: $date $title ($($newPaths.Count) photos)" | Out-Null
  Write-Host "  업로드(push) 중..." -ForegroundColor Cyan
  git push origin main
  if ($LASTEXITCODE -ne 0) { throw "git push 실패. 인터넷 연결을 확인하고 다시 시도하세요." }

  Write-Host ""
  Write-Host "  ========================================" -ForegroundColor Green
  Write-Host "   완료! 1~2분 뒤 사이트에 반영됩니다." -ForegroundColor Green
  Write-Host "   https://crchoi-lab.kr/photo.html" -ForegroundColor Green
  Write-Host "  ========================================" -ForegroundColor Green
}
catch {
  Write-Host ""
  Write-Host "  [오류] $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "  로컬 변경사항은 남아있습니다." -ForegroundColor Yellow
}
finally {
  Pop-Location
}
