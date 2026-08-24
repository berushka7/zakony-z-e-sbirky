<#
.SYNOPSIS
Vypíše text jednoho ustanovení napříč všemi zněními předpisu — odpověď na otázku „změnilo se to?".

.DESCRIPTION
Vzniklo při, kde se u každé konstanty musí rozhodnout, jestli se ustanovení, ze kterého
čerpáme, mezi roky měnilo. Stahovat kvůli tomu celá znění je nepoměr: zákon 48/1997 má 94 znění
a 1 634 fragmentů, kdežto § 9 odst. 2 jsou dvě věty.

⚠️ NEODPOVÍDÁ na to, jestli se změnil zbytek předpisu — jen ten jeden fragment. Když se ukáže,
že se ustanovení měnilo, stáhni obě znění skriptem `fetch-zakon.ps1` a porovnej `git diff --no-index`.

.PARAMETER Rok
Rok vyhlášení, např. 1997.

.PARAMETER Cislo
Číslo předpisu, např. 48.

.PARAMETER Fragment
Identifikátor fragmentu z url e-Sbírky, BEZ `#` — např. `par_9-odst_2` nebo `par_14-odst_5`.
Bere se jako PŘEDPONA, takže `par_9` vypíše i všechny jeho odstavce.

.PARAMETER Od
Nejstarší znění, které se má porovnávat (yyyy-MM-dd). Bez něj se berou znění od $VychoziOd.

.EXAMPLE
.\tools\zakony\porovnat-paragraf.ps1 -Rok 1997 -Cislo 48 -Fragment par_9-odst_2
Vypíše, jak zní § 9 odst. 2 v každém znění od roku 2025 — a jestli se text mění.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Rok,
    [Parameter(Mandatory)][int]$Cislo,
    [Parameter(Mandatory)][string]$Fragment,
    [string]$Od
)

$ErrorActionPreference = 'Stop'

$Endpoint = 'https://opendata.eselpoint.gov.cz/sparql'
$Slovnik  = 'https://slovník.gov.cz/datový/sbírka/pojem/'

# Stejná hranice jako $NejstarsiPocitanyRok ve `fetch-zakon.ps1` — starší znění nás nezajímají,
# protože za ta období aplikace nepočítá.
$VychoziOd = '2025-01-01'
if (-not $Od) { $Od = $VychoziOd }

function Invoke-Sparql([string]$Query) {
    $r = Invoke-RestMethod -Uri $Endpoint -Method Post -Body @{
        query = $Query; format = 'application/sparql-results+json'
    } -ContentType 'application/x-www-form-urlencoded' -Headers @{ Accept = 'application/sparql-results+json' }
    return $r.results.bindings
}

# --- která znění předpis má ----------------------------------------------------------------
$zneni = @(Invoke-Sparql @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?zneni WHERE {
  ?o s:url-fragmentu-znění ?url .
  FILTER(STRSTARTS(?url, "/sb/$Rok/$Cislo/"))
  BIND(REPLACE(?url, "^/sb/$Rok/$Cislo/([0-9-]+)#.*`$", "`$1") AS ?zneni)
} ORDER BY ?zneni
"@ | ForEach-Object { $_.zneni.value } |
     Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' -and $_ -ge $Od })

if (-not $zneni) { throw "Předpis $Cislo/$Rok Sb. nemá žádné znění od $Od." }

Write-Host "Předpis $Cislo/$Rok Sb., fragment '$Fragment' — $($zneni.Count) znění od $Od`n"

# --- týž fragment v každém znění -----------------------------------------------------------
$predchozi = $null
$zmen = 0

foreach ($z in $zneni) {
    # ⛔ ŽÁDNÉ `má-předka+`. Tranzitivní cesta s filtrovanou kotvou vrací 502 (ověřeno i tady);
    # projde jen kotvená na konkrétní URI. Tenhle tvar — uzel s url + jeho PŘÍMÉ děti — je týž,
    # jaký používá hlavní dotaz `fetch-zakon.ps1`, a spolehlivě prochází.
    $rows = @(Invoke-Sparql @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?poradi ?text WHERE {
  { ?o s:url-fragmentu-znění ?u . FILTER(STRSTARTS(?u, "/sb/$Rok/$Cislo/$z#$Fragment")) }
  UNION
  { ?o s:má-předka ?p . ?p s:url-fragmentu-znění ?u . FILTER(STRSTARTS(?u, "/sb/$Rok/$Cislo/$z#$Fragment")) }
  ?o s:pořadí-fragmentu-znění-právního-aktu ?poradi ; s:obsahuje-fragment ?f .
  ?f s:text-fragmentu ?text .
} ORDER BY ?poradi
"@)

    $text = (($rows | ForEach-Object { $_.text.value -replace '<[^>]+>', '' }) -join ' ').Trim()
    $text = [System.Net.WebUtility]::HtmlDecode($text) -replace '\s+', ' '

    if (-not $text) {
        Write-Host "$z  ⚠️ fragment v tomto znění NENÍ (jiné číslování, nebo zrušen)" -ForegroundColor Yellow
    }
    elseif ($null -eq $predchozi) {
        Write-Host "$z  $text"
    }
    elseif ($text -eq $predchozi) {
        Write-Host "$z  (beze změny)" -ForegroundColor DarkGray
    }
    else {
        $zmen++
        Write-Host "$z  ⛔ ZMĚNA:" -ForegroundColor Red
        Write-Host "     $text"
    }
    if ($text) { $predchozi = $text }

    # WAF blokuje podle frekvence — bez odstupu začne vracet 403 (viz komentář v `Invoke-Sparql`).
    Start-Sleep -Seconds 4
}

Write-Host ""
if ($zmen -eq 0) {
    Write-Host "✅ Znění se v tomhle ustanovení neliší — konstanta odvozená z něj platí pro celé období." -ForegroundColor Green
} else {
    Write-Host "⛔ $zmen změn. Konstanta klíčovaná rokem se musí rozlišit; stáhni dotčená znění a porovnej celé." -ForegroundColor Red
}
