from pathlib import Path
import json
R=Path('.')

def rd(p): return p.read_text('utf-8-sig')
def bom(p,s): p.write_bytes(b'\xef\xbb\xbf'+s.encode('utf-8'))

def rep(s,a,b,name):
    if a not in s: raise SystemExit('missing '+name)
    return s.replace(a,b,1)

# api_v2: current branch already contains inner-exception/TLS/MIME patch.
p=R/'_system/start/api_v2.ps1'; s=rd(p)
s=rep(s,"        max_reference_images = 4\n","        max_reference_images = 2\n        transport_profile = 'r3_120s_safe'\n",'api defaults')
a="""        $defaults = Get-DefaultTinySnowConfigV2
        foreach ($name in $defaults.Keys) {
            if (-not ($loaded.PSObject.Properties.Name -contains $name)) {
                Add-Member -InputObject $loaded -NotePropertyName $name -NotePropertyValue $defaults[$name]
            }
        }
        return $loaded
"""
b="""        $defaults = Get-DefaultTinySnowConfigV2
        $needsSave = $false
        foreach ($name in $defaults.Keys) {
            if (-not ($loaded.PSObject.Properties.Name -contains $name)) {
                Add-Member -InputObject $loaded -NotePropertyName $name -NotePropertyValue $defaults[$name]
                $needsSave = $true
            }
        }
        if ([int]$loaded.max_reference_images -lt 1 -or [int]$loaded.max_reference_images -gt 2) { $loaded.max_reference_images = 2; $needsSave = $true }
        if ([string]$loaded.transport_profile -ne 'r3_120s_safe') { $loaded.transport_profile = 'r3_120s_safe'; $loaded.max_reference_images = 2; $needsSave = $true }
        if ($needsSave) { Save-TinySnowConfigV2 $loaded }
        return $loaded
"""
s=rep(s,a,b,'api migration')
s=rep(s,"        $client.DefaultRequestHeaders.ExpectContinue = $false\n        $form = New-Object System.Net.Http.MultipartFormDataContent\n","        $client.DefaultRequestHeaders.ExpectContinue = $false\n        $client.DefaultRequestHeaders.ConnectionClose = $true\n        $form = New-Object System.Net.Http.MultipartFormDataContent\n",'connection close')
s=rep(s,"        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality)\n        $response = $client.PostAsync($endpoint, $form).GetAwaiter().GetResult()\n","        $requestStarted = Get-Date\n        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality)\n        $response = $client.PostAsync($endpoint, $form).GetAwaiter().GetResult()\n",'request timing')
a="""        $path = Save-B64ImageV2 $json 'edit'
        Write-TinySnowLogV2 '圖生圖' $endpoint $summary $true '' $path
        return $path
    }
    catch {
        $message = Protect-SecretTextV2 (Get-HttpErrorTextV2 $_.Exception) ([string]$Config.api_key)
        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality)
"""
b="""        $path = Save-B64ImageV2 $json 'edit'
        $elapsed = [int]((Get-Date) - $requestStarted).TotalSeconds
        $summary += ('; elapsed_seconds=' + $elapsed)
        Write-TinySnowLogV2 '圖生圖' $endpoint $summary $true '' $path
        return $path
    }
    catch {
        $message = Protect-SecretTextV2 (Get-HttpErrorTextV2 $_.Exception) ([string]$Config.api_key)
        $elapsed = 0
        if ($null -ne $requestStarted) { $elapsed = [int]((Get-Date) - $requestStarted).TotalSeconds }
        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality + '; elapsed_seconds=' + $elapsed)
"""
s=rep(s,a,b,'api elapsed log'); bom(p,s)

# Menu + visible build marker.
p=R/'_system/start/menu_beginner.ps1'; s=rd(p)
s=s.replace("$host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2'","$host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2 | API-R3-120S'",1)
s=s.replace("    Write-Host '蝦皮商品圖片優化工具 V2'\n    Write-Host 'SAFE TEST MODE｜一次一件、最多5張' -ForegroundColor Green\n","    Write-Host '蝦皮商品圖片優化工具 V2'\n    Write-Host 'Build: API-R3-120S｜120秒超時防護版' -ForegroundColor Yellow\n    Write-Host 'SAFE TEST MODE｜一次一件、最多5張｜每次最多2張壓縮參考圖' -ForegroundColor Green\n",1)
s=s.replace('請輸入 1 到 4（Enter 保留）','請輸入 1 或 2（Enter 保留）',1)
s=s.replace("if ($newMaximum -notmatch '^[1-4]$') { throw '請輸入 1、2、3 或 4。' }","if ($newMaximum -notmatch '^[1-2]$') { throw '120秒超時防護版請輸入 1 或 2。' }",1)
bom(p,s)

# Config example + build file.
p=R/'_system/config/config.example.json'; d=json.loads(rd(p)); d['max_reference_images']=2; d['transport_profile']='r3_120s_safe'; p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(R/'V2_BUILD.txt').write_text('''Shopee TinySnow Image Tool V2\nBuild: API-R3-120S\nDate: 2026-08-14\nRuntime: Windows PowerShell 5.1 compatible\nTransport profile: max 2 compressed JPEG references; adaptive medium -> low -> 1-reference retry on transport timeout.\nSTART.bat runs UTF-8 BOM normalization and self-check before the menu opens.\n''',encoding='utf-8')
