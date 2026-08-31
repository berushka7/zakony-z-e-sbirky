<#
.SYNOPSIS
Stáhne úplné znění právního předpisu z otevřených dat e-Sbírky (ELI) do repa.

.DESCRIPTION
Proč to existuje: agent se k textu zákona přes běžné weby nedostane — zakonyprolidi.cz
i e-sbirka.gov.cz vrací robotům 403. Otevřená data e-Sbírky ale 403 nevrací a mají text
v predikátu `text-fragmentu`.

⚠️ Do repa se ukládá JEN to, co stáhne tenhle skript. Ručně opsané ani přes model
"přeříkané" znění tam nepatří — u právního textu je i překlep v jednom slově chyba
(ověřeno: shrnující model při čtení udělal z "poměrně" → "proporčně" a z "jedná se"
→ "jde se").

Proč celé znění a ne výňatek: výňatek neumí zachytit NOVÝ odstavec. Kontrola
"citovaný text se nezměnil" pak dá falešné zelené světlo přesně tam, kde je riziko.
Se dvěma staženými zněními stačí `git diff`.

.PARAMETER Rok
Rok vyhlášení, např. 1992.

.PARAMETER Cislo
Číslo předpisu, např. 592.

.PARAMETER Zneni
Datum účinnosti znění (yyyy-MM-dd). Bez něj se jen vypíšou dostupná znění.

.EXAMPLE
.\fetch-zakon.ps1 -Rok 1992 -Cislo 592
Vypíše seznam všech znění (včetně budoucích).

.EXAMPLE
.\fetch-zakon.ps1 -Rok 1992 -Cislo 592 -Zneni 2026-05-27
Stáhne znění do zneni/1992-592-2026-05-27.md (v aktuálním adresáři; jinam přes -OutDir).
#>
[CmdletBinding(DefaultParameterSetName = 'Fetch')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Fetch')][int]$Rok,
    [Parameter(Mandatory, ParameterSetName = 'Fetch')][int]$Cislo,
    [Parameter(ParameterSetName = 'Fetch')][string]$Zneni,

    # Projde všechna uložená znění a ohlásí, jestli mezitím nepřibylo novější — a jestli
    # naopak některé uložené nepřestalo dávat smysl (viz -NejstarsiRok).
    [Parameter(Mandatory, ParameterSetName = 'Check')][switch]$Check,

    # Kam se ukládá; výchozí je podadresář `zneni` v aktuálním adresáři (viz níže).
    [string]$OutDir,

    # ⛔ Řídí, KTERÁ ZNĚNÍ SMÍ ZMIZET. Znění účinné kdykoli od tohohle roku dál je pořád živý
    # podklad, i když ho mezitím přebilo novější — protože se podle něj počítají minulá období.
    # Kdo řeší jen současnost, může si ho zvednout; kdo počítá zpětně, ne.
    [int]$NejstarsiRok = 2025
)

$ErrorActionPreference = 'Stop'

$Endpoint = 'https://opendata.eselpoint.gov.cz/sparql'
$Slovnik  = 'https://slovník.gov.cz/datový/sbírka/pojem/'
# ⚠️ Výchozí cíl je `zneni` v AKTUÁLNÍM adresáři, ne vedle skriptu. Dokud se repozitář jen
# klonoval, bylo to totéž — jenže jako nainstalovaný skill leží skript v adresáři Claude Code
# (`~/.claude/skills/…`, u pluginu v adresáři pluginu) a `$PSScriptRoot` by stahoval znění TAM:
# do složky, kterou uživatel nemá v gitu, nevidí do ní, a při aktualizaci skillu o ni přijde.
# Stažené znění patří k projektu, který ho cituje.
if (-not $OutDir) { $OutDir = Join-Path (Get-Location).Path 'zneni' }
$NejstarsiPocitanyRok = $NejstarsiRok

# ⛔ CO SE SEM UKLÁDÁ VŮBEC (ověřeno 8/2026). Uložením předpisu si ho
# BEREME DO HLÍDÁNÍ: `-Check` pak u každé novely hlásí „přibylo novější znění". To se vyplatí
# u předpisů, ze kterých čerpáme hodně a kde nás změna opravdu zajímá.
#
# ⚠️ Nevyplatí se to u předpisu, ze kterého potřebujeme JEDINOU STABILNÍ VĚTU. Příklad: zákon
# 48/1997 Sb. (§ 9 odst. 2 — dělení zdravotního pojistného na třetiny) se novelizuje několikrát
# ročně a má 94 znění, kdežto ta věta stojí od roku 1997. Uložený by trvale plnil `-Check` šumem
# — a nález, který se objevuje pořád u souboru, co má zůstat, naučí čtenáře přehlížet i ty vážné.
#
# 💡 Pro takové případy je `porovnat-paragraf.ps1`: vypíše JEDEN fragment napříč zněními a řekne,
# jestli se měnil, bez stahování čehokoli. Citace pak žije u konstanty v kódu i s tím, kdy a jak
# se ověřovala.

function Invoke-Sparql([string]$Query) {
    # ⛔ PŘED ENDPOINTEM SEDÍ WAF a blokuje část SPARQL funkcí (ověřeno 8/2026).
    # Vrátí HTML „The request is blocked", ne SPARQL chybu, takže to na první pohled vypadá jako
    # výpadek služby. Ověřeno pokusem:
    #
    #   STRSTARTS  … projde        CONTAINS … BLOKOVÁNO
    #   UNION      … projde        STR(?x)  … BLOKOVÁNO
    #   OPTIONAL   … projde        ?s ?p ?o s proměnným predikátem přes celý graf … BLOKOVÁNO
    #
    # Filtrovat se tedy musí přes STRSTARTS, nebo až na naší straně v PowerShellu. Průzkum
    # struktury dat jde dělat dotazem na KONKRÉTNÍ URI (`SELECT ?p ?v WHERE { <uri> ?p ?v }`),
    # ten projde. Dotazy taky nepouštěj v rychlém sledu — po několika za sebou začne blokovat
    # i to, co předtím prošlo.
    #
    # ⚠️ Blokuje i podle OBSAHU dotazu, ne jen podle frekvence (ověřeno 8/2026). Řízená dvojice
    # z téže IP v rozestupu vteřin, jediný rozdíl je znak `#` v řetězci filtru:
    #
    #   STRSTARTS(?u, "/sb/2004/235/2026-01-01#")  … 403
    #   STRSTARTS(?u, "/sb/2004/235/2026-01-01")   … 200 a data
    #
    # `#` ale není jediný spouštěč — širší filtr "/sb/2004/235/" vrátil 403 taky, bez něj.
    # Ověřeno přes GET; POST s `#` týž den prošel, takže se to na tenhle skript nemusí vztahovat.
    #
    # 💡 KDYŽ BLOKACE VISÍ NA SÍTI, zkus dotaz z JINÉ IP dřív, než se čeká na jinou linku:
    # endpoint bere dotazy i přes GET (`?query=…&format=…`), takže se dá poslat jako obyčejná URL
    # odkudkoli. Diakritika v predikátech se přitom obejde SPARQL escapy — `slovn\u00EDk`,
    # `zn\u011Bn\u00ED` — čímž je dotaz čistě ASCII a nemá se co cestou rozsypat.
    #
    # POST, ne GET: dotazy jsou dlouhé a diakritika v URL je zbytečná past.
    $response = Invoke-RestMethod -Uri $Endpoint -Method Post -Body @{
        query  = $Query
        format = 'application/sparql-results+json'
    } -ContentType 'application/x-www-form-urlencoded' -Headers @{ Accept = 'application/sparql-results+json' }

    return $response.results.bindings
}

function Get-Zneni([int]$r, [int]$c) {
    $q = @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?zneni WHERE {
  ?o s:url-fragmentu-znění ?url .
  FILTER(STRSTARTS(?url, "/sb/$r/$c/"))
  BIND(REPLACE(?url, "^/sb/$r/$c/([0-9-]+)#.*`$", "`$1") AS ?zneni)
} ORDER BY ?zneni
"@
    # ⛔ Odfiltrovat, co se nepodařilo zredukovat na datum. `REPLACE` výš počítá s `#`, které má
    # url FRAGMENTU — ale každé znění má i KOŘENOVÝ uzel s url bez `#` („/sb/1997/48/2025-01-01"),
    # na který vzor nesedí a vrátí se celá cesta. Ve výpisu to zdvojovalo každé znění a do `-Check`
    # to pouštělo řetězce, které se pak porovnávaly s datem (ověřeno 8/2026).
    return @(Invoke-Sparql $q | ForEach-Object { $_.zneni.value } |
             Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' })
}

# --- kontrolní režim --------------------------------------------------------------------

if ($Check) {
    # ⚠️ Tohle je ta část, kvůli které se úplná znění vůbec ukládají: „zestárla nám kopie?"
    # musí být DOTAZ, ne domněnka. Bez toho by uložený zákon byl jen hezčí verze problému,
    # kvůli kterého se dřív neukládal vůbec.
    if (-not (Test-Path $OutDir)) { throw "Složka $OutDir neexistuje — není co kontrolovat." }

    $ulozene = Get-ChildItem $OutDir -Filter '*.md' | Where-Object { $_.BaseName -match '^(\d{4})-(\d+)-(\d{4}-\d{2}-\d{2})$' }
    $dnes = Get-Date -Format 'yyyy-MM-dd'
    $nalezy = @()

    foreach ($grp in ($ulozene | Group-Object { ($_.BaseName -split '-')[0, 1] -join '-' })) {
        $parts = $grp.Name -split '-'
        $r = [int]$parts[0]; $c = [int]$parts[1]
        $mame = @($grp.Group | ForEach-Object { $_.BaseName -replace '^\d{4}-\d+-', '' } | Sort-Object)

        Write-Host "Kontroluji $c/$r Sb. (uloženo: $($mame -join ', '))…"
        $vsechna = Get-Zneni $r $c
        if (-not $vsechna) { $nalezy += "⚠️ $c/$r Sb. — seznam znění se nepodařilo načíst"; continue }

        # Účinné dnes = poslední znění s datem <= dnes.
        $aktualni = @($vsechna | Where-Object { $_ -le $dnes } | Select-Object -Last 1)
        $budouci = @($vsechna | Where-Object { $_ -gt $dnes })

        if ($aktualni -and $mame -notcontains $aktualni[0]) {
            $nalezy += "⛔ $c/$r Sb. — účinné znění je $($aktualni[0]), ale to uložené NENÍ. Stáhni ho."
        }
        foreach ($b in $budouci) {
            if ($mame -notcontains $b) {
                $nalezy += "⚠️ $c/$r Sb. — existuje BUDOUCÍ znění $b, které uložené není."
            }
        }
        # ⛔ „Existuje novější znění" NENÍ důvod ke smazání (ověřeno 8/2026). To pravidlo
        # platí pro toho, kdo řeší jen současnost — my počítáme i minulá období, takže znění
        # účinné třeba jen půl roku 2026 je pro tu polovinu roku ten správný podklad.
        # Smazat smí jít až znění, jehož účinnost SKONČILA CELÁ před rokem $NejstarsiPocitanyRok.
        #
        # ⚠️ Je to zároveň obrana proti otupení kontroly: nález, který se objevuje každý týden
        # u souboru, co má zůstat, naučí čtenáře přehlížet i ⛔ nálezy, kvůli kterým check je.
        $hranice = "$NejstarsiPocitanyRok-01-01"
        foreach ($m in $mame) {
            # Konec účinnosti = začátek nejbližšího následujícího znění; poslední znění nekončí.
            $konec = @($vsechna | Where-Object { $_ -gt $m } | Select-Object -First 1)
            if ($konec -and $konec[0] -le $hranice) {
                $nalezy += "🗑️ $c/$r Sb. — znění $m přestalo platit $($konec[0]), tedy před rokem " +
                           "$NejstarsiPocitanyRok, od kterého počítáme. Můžeš ho smazat."
            }
        }
    }

    if ($nalezy) {
        "`nNálezy:"
        $nalezy | ForEach-Object { "  $_" }
        exit 1
    }

    "`n✅ Všechna uložená znění jsou aktuální a žádné budoucí nechybí."

    # ⚠️ `exit 0`, ne `return`: po `return` zůstane $LASTEXITCODE prázdný a volající, který
    # testuje `$code -ne 0`, dostane TRUE (v PowerShellu je $null -ne 0 pravda) — workflow by
    # hlásilo nález i při čistém stavu. Odhalil to negativní test, ne běžný běh.
    exit 0
}

# --- seznam znění -----------------------------------------------------------------------

$akt = "https://opendata.eselpoint.gov.cz/esel-esb/eli/cz/sb/$Rok/$Cislo"

if (-not $Zneni) {
    "Dostupná znění předpisu $Cislo/$Rok Sb.:"
    Get-Zneni $Rok $Cislo | ForEach-Object { "  $_" }
    "`nStáhni konkrétní: .\fetch-zakon.ps1 -Rok $Rok -Cislo $Cislo -Zneni <datum>"
    return
}

# --- stažení znění ----------------------------------------------------------------------

# Fragmenty se berou po dávkách: celý zákon jich má stovky a Virtuoso má strop na řádky.
$all = @()
$offset = 0
$batch = 1000

do {
    # ⛔ SCOPE NESMÍ STÁT JEN NA `url-fragmentu-znění` (ověřeno 8/2026).
    #
    # Nadpis paragrafu a NÁVĚTÍ (uvozující věta před výčtem písmen) jsou v datech samostatné
    # uzly, které `url-fragmentu-znění` NEMAJÍ — visí na paragrafu přes `má-předka`. Dotaz, který
    # se na tu url vázal, je tedy nevracel vůbec:
    #
    #   /2/1/6/2/25/     § 101c                                          ← vracelo se
    #   /2/1/6/2/25/1/   Povinnost podat kontrolní hlášení                ← CHYBĚLO (nadpis §)
    #   /2/1/6/2/25/2/   Plátce je povinen podat kontrolní hlášení, pokud ← CHYBĚLO (návětí)
    #   /2/1/6/2/25/2/1/ a) uskutečnil zdanitelné plnění…                 ← vracelo se
    #
    # ⚠️ Nešlo jen o návětí u paragrafů bez odstavců, jak issue předpokládala — v uložených
    # zněních chyběly NADPISY VŠECH PARAGRAFŮ. Soubor přitom vypadal úplný; to je na tom to
    # nebezpečné, protože z výčtu bez uvozující věty jde v dobré víře vyvodit nesmysl.
    #
    # Řeší to UNION: uzly s url + jejich potomci, kteří url nemají. Řadicí klíč u obojích JE, takže
    # řazení dál dělá všechnu práci (nadpis a návětí padnou správně mezi § a písmena).
    #
    # ⚠️ JEDNA ÚROVEŇ NESTAČÍ a hlubší dotaz server NEUNESE — proto se dobírá druhým průchodem
    # níž (ověřeno 8/2026). Tři formulace vyzkoušené na ZDPH skončily všechny `502 Proxy Error`:
    #   `má-předka+` s kotvou na kořeni (filtr bez `#`)   … 502
    #   `má-předka+` s kotvou na paragrafech              … 502
    #   ručně napsaná druhá úroveň jako třetí větev UNION … 502
    # `má-předka+` omezená na JEDEN uzel přitom projde okamžitě. Zvětšovat dotaz tedy nemá smysl;
    # dobírá se cíleně, viz `Get-Podstrom` a druhý/třetí průchod níž.
    #
    # ⛔ `?text` JE OPTIONAL SCHVÁLNĚ, i když textové uzly jsou to jediné, co se do souboru píše.
    # Uzly BEZ textu jsou totiž právě ty mezilehlé, pod kterými visí nedosažitelné tělo paragrafu
    # — a s povinným textem jsou NEVIDITELNÉ. Takhle se z nich stane seznam míst k dobrání.
    # U ZDPH jsou takové uzly tři (§§ 111, 112, 113), takže je to levné.
    #
    # ⚠️ DISTINCT je povinný — uzel, který url má a zároveň je dítětem uzlu s url, projde oběma
    # větvemi a bez něj by se text v souboru zdvojil.
    #
    # ⛔ ŘADÍ SE PODLE `pořadí-…`, NE `hierarchie-…` (ověřeno 8/2026). e-Sbírka mezi
    # 22. a 23.8.2026 změnila datový model: `hierarchie-fragmentu-znění-právního-aktu` s cestou
    # "/2/1/6/2/" u nově vygenerovaných zněních (ZDPH i daňový řád k 1.1.2026) UŽ NENÍ a nahradil
    # ji `pořadí-fragmentu-znění-právního-aktu` s hex klíčem "6ADAF6BD60". Starší znění nesou
    # zatím OBOJÍ, takže nový klíč je univerzální a zpětná větev není potřeba.
    #
    # ⚠️ Vypadalo to jako „část zákona zmizela" — nezmizela, jen se přejmenoval predikát. Dotaz
    # na jednu url vracel fragmenty dál, teprve spojení s hierarchií padalo na nulu.
    $q = @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?o ?poradi ?citace ?text WHERE {
  { ?o s:url-fragmentu-znění ?u . FILTER(STRSTARTS(?u, "/sb/$Rok/$Cislo/$Zneni#")) }
  UNION
  { ?o s:má-předka ?rodic . ?rodic s:url-fragmentu-znění ?u . FILTER(STRSTARTS(?u, "/sb/$Rok/$Cislo/$Zneni#")) }
  ?o s:pořadí-fragmentu-znění-právního-aktu ?poradi .
  OPTIONAL { ?o s:citace-označení-fragmentu-znění-právního-aktu ?citace }
  OPTIONAL { ?o s:obsahuje-fragment ?f . ?f s:text-fragmentu ?text }
}
ORDER BY ?poradi
LIMIT $batch OFFSET $offset
"@
    $rows = @(Invoke-Sparql $q)
    $all += $rows
    $offset += $batch
    Write-Host "  staženo $($all.Count) uzlů…"
} while ($rows.Count -eq $batch)

if ($all.Count -eq 0) {
    throw "Znění $Zneni předpisu $Cislo/$Rok Sb. nevrátilo žádné fragmenty. Existuje? Spusť skript bez -Zneni."
}

# --- druhý průchod: dobrat text tam, kam první nedosáhl -----------------------------------

# Podstrom JEDNOHO uzlu. Kotva je konkrétní URI, takže `má-předka+` je tady levná — na rozdíl
# od téhož dotazu nad celým předpisem, kde server vrací 502 (viz komentář výš).
function Get-Podstrom([string]$uri) {
    return @(Invoke-Sparql @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?o ?poradi ?citace ?text WHERE {
  ?o s:má-předka+ <$uri> ;
     s:pořadí-fragmentu-znění-právního-aktu ?poradi ;
     s:obsahuje-fragment ?f .
  OPTIONAL { ?o s:citace-označení-fragmentu-znění-právního-aktu ?citace }
  ?f s:text-fragmentu ?text .
}
"@)
}

# ⛔ DOBÍRÁ SE PODLE „MÁ DĚTI BEZ URL", NE PODLE „NEMÁ TEXT" (ověřeno 8/2026).
#
# První verze hledala uzly BEZ TEXTU — a minula tenhle případ: uzel může
# mít text A ZÁROVEŇ potomky. V přílohách ZDPH takových bylo 13 a tiše vypadávaly.
#
# 💡 Rozhoduje url, ne text: dítě, které url MÁ (odstavec, písmeno), si vezme první větev
# hlavního dotazu sama. Ztratit se může jen potomek uzlu bez url — a jen ten se dobírá.
# Podmínka „nemá text" je tímhle pokrytá taky, takže se nemusí testovat zvlášť.
$rodice = @(Invoke-Sparql @"
PREFIX s: <$Slovnik>
SELECT DISTINCT ?dite WHERE {
  ?par s:url-fragmentu-znění ?u .
  FILTER(STRSTARTS(?u, "/sb/$Rok/$Cislo/$Zneni#"))
  ?dite s:má-předka ?par .
  OPTIONAL { ?dite s:url-fragmentu-znění ?du }
  FILTER(!BOUND(?du))
  ?vnuk s:má-předka ?dite .
  OPTIONAL { ?vnuk s:url-fragmentu-znění ?vu }
  FILTER(!BOUND(?vu))
}
"@) | ForEach-Object { $_.dite.value }

if ($rodice) {
    Write-Host "  dobírám $($rodice.Count) míst, kam první průchod nedosáhl…"
    foreach ($uzel in $rodice) { $all += Get-Podstrom $uzel }
}

# --- třetí průchod: části dokumentu mimo `norma` -------------------------------------------

# ⛔ Dokument má víc větví než jen `norma` — u ZDPH `prefix` (vyhlašovací věta: „235 / ZÁKON /
# ze dne 1. dubna 2004 / Parlament se usnesl…") a `postfix` (podpisy „Zaorálek v. r."). Ty url
# s `#` nemají, takže je hlavní filtr nepustí dovnitř a ve VŠECH uložených zněních chyběly.
#
# 💡 Které větve dobrat, se NEHÁDÁ podle názvu — vezmou se děti kořene, ze kterých první průchod
# nepřinesl ani jeden uzel. Tím se to samo přizpůsobí i dokumentu stavěnému jinak.
$koren = @($all | ForEach-Object { $_.o.value } |
    Where-Object { $_ -match '^(.*/dokument)(/|$)' } |
    ForEach-Object { $Matches[1] } | Select-Object -Unique)

if ($koren.Count -eq 1) {
    $deti = @(Invoke-Sparql @"
PREFIX s: <$Slovnik>
SELECT ?o WHERE { ?o s:má-předka <$($koren[0])> }
"@) | ForEach-Object { $_.o.value }

    $mame = [System.Collections.Generic.HashSet[string]]::new([string[]]@($all | ForEach-Object { $_.o.value }))
    foreach ($vetev in $deti) {
        if (@($mame | Where-Object { $_.StartsWith("$vetev/") -or $_ -eq $vetev }).Count -gt 0) { continue }
        Write-Host "  dobírám větev $($vetev -replace '.*/','')…"
        $all += Get-Podstrom $vetev
    }
}

# Uzel se mohl vrátit z víc průchodů najednou — do souboru patří jednou.
$all = @($all | Group-Object { $_.o.value } | ForEach-Object { $_.Group[0] })

# `pořadí-fragmentu-znění-právního-aktu` je hex řetězec, ve kterém POTOMEK PRODLUŽUJE PŘEDPONU
# RODIČE — a proto se řadí prostým porovnáním znak po znaku, bez jakéhokoli přepočtu:
#
#   00 → 6AC0 (ČÁST 1) → 6ADA (HLAVA 1) → 6ADAD0 (§ 1) → 6ADAF0 (§ 2)
#      → 6ADAF680 (§ 2 odst. 1) → 6ADAF6AC (písm. a) → 6ADAF6BD60 (bod 1)
#
# Kratší klíč je předponou delšího, takže rodič vyjde před svými dětmi sám od sebe.
#
# ⛔ POROVNÁVAT ORDINÁLNĚ, ne podle jazykových pravidel. `Sort-Object` na řetězcích porovnává
# podle KULTURY, a to je u řadicího klíče špatný nástroj: co je „správné pořadí písmen" v češtině
# (viz `PismenaSeRadiCesky`, kde „ch" patří až za „h") nemá u hexadecimálního klíče co dělat.
# Tady musí platit prosté pořadí znaků, jinak by se řazení mohlo tiše rozejít podle nastavení
# stroje — a soubor by zase vypadal úplný, jen s přeházenými paragrafy (to je přesně chyba,
# která tu jednou unikla na půl roku).
#
# 💡 Dřívější klíč byl cesta "/2/1/2/14/", kde bylo potřeba čísla vycpat
# nulami (lexikálně `10` < `2`). Hex klíč tenhle celý problém ruší — proto tu žádný převod není.
function Sort-ByPoradi($rows) {
    $list = [System.Collections.Generic.List[object]]::new()
    $rows | ForEach-Object { $list.Add($_) }
    $list.Sort([System.Comparison[object]] {
        param($a, $b)
        [string]::CompareOrdinal($a.poradi.value, $b.poradi.value)
    })
    return $list
}

$sorted = Sort-ByPoradi $all

# --- inline značky e-Sbírky ----------------------------------------------------------------

# Text fragmentu nese HTML e-Sbírky. Čtyři druhy, a jen dva z nich něco znamenají:
#
#   <var>       obal kolem „(1)" nebo „§ 8"        → zahodit, obsah zůstává
#   <a href…>   odkaz na jiný § nebo na EUR-Lex    → zahodit, obsah zůstává
#   <sup>       ODKAZ NA POZNÁMKU POD ČAROU        → ⛔ nese význam
#   <br/>       ZALOMENÍ ŘÁDKU                     → ⛔ nese význam
#
# ⛔ Do 24.8.2026 se zahazovaly všechny čtyři (ověřeno 8/2026):
#   • z „Evropské unie<sup>1</sup>)" bylo „Evropské unie1)" — číslo poznámky splynulo se slovem
#     a v textu o daních vypadá jako součást věty;
#   • poznámka pod čarou č. 1 zákona o účetnictví vyjmenovává SEDM SMĚRNIC, každou na vlastním
#     řádku — bez <br/> z toho byl jeden odstavec o 1 300 znacích, kde jedna směrnice končí
#     tečkou a hned za mezerou začíná další.
#
# ⛔ VELIKOST PÍSMEN SE NEUPRAVUJE. Na e-Sbírce svítí název zákona verzálkami
# („O DANI Z PŘIDANÉ HODNOTY"), ale v datech je fragment doslova `o dani z přidané hodnoty` —
# malými. Verzálky přidává až sazba. Že soubor jinde velká písmena má (`ZÁKON`, `ČÁST PRVNÍ`,
# `VYHLÁŠKA`) NENÍ nedůslednost, ale důkaz věrnosti: kde jsou v datech, tam jsou i tady.
# Ověřeno na dvou předpisech (235/2004 i 457/2020 mají týž vzorec), ověřeno na dvou předpisech.
#
# 💡 PĚTIVTEŘINOVÝ TEST, až to zas někoho zarazí: označ ten název na e-Sbírce a zkopíruj ho.
# Do schránky padnou MALÁ písmena. Verzálky dělá `text-transform` v CSS — mění vzhled, ne obsah,
# a schránka nese obsah. (Přímý důkaz, ne odvození z dat.)
#
# ⚠️ „Srovnat to podle webu" by znamenalo DOPSAT DO ZÁKONA znaky, které ve zdroji nejsou.
function ConvertTo-CistyText([string]$html) {
    # Horní index Unicodem, ne `<sup>`: tyhle soubory se podstatně častěji čtou jako HOLÝ TEXT
    # (grep, čtení agentem) než renderují, a „unie¹⁾" je čitelné v obojím, kdežto
    # „unie<sup>1</sup>)" jen v renderovaném. 
    #
    # ⚠️ Závorka jde do horního indexu TAKY, ačkoli ji zdroj má mimo (`<sup>1</sup>)`). Je to
    # čistě otázka sazby — `⁾` je pořád pravá závorka, takže se tím zákon nemění a marker je
    # v textu jednoznačný. Kdyby zůstala dole, „unie¹)" vypadá jako zbloudilá závorka.
    # Tabulky NEJDŘÍV — jinak by z nich obecné ořezání značek udělalo slepenec bez oddělovačů.
    $t = [regex]::Replace($html, '(?s)<table[^>]*>.*?</table>', {
        param($m) ConvertTo-Tabulka $m.Value })

    $t = [regex]::Replace($t, '<sup>(.*?)</sup>(\s*\))?', {
        param($m) ConvertTo-HorniIndex ($m.Groups[1].Value + $m.Groups[2].Value) })

    $t = $t -replace '<br\s*/?>', "`n"     # skutečné zalomení, ne mezera

    # ⛔ `<img>` SE NESMÍ JEN ZAHODIT. Nekteré přílohy nejsou text, ale VLOŽENÝ DOKUMENT — příloha
    # č. 14 vyhlášky 457/2020 je PDF formulář vložený jako obrázek. Po obecném ořezu zbyl holý
    # nadpis „Příloha č. 14" a to se čte jako „příloha je prázdná", což je nepravda: příloha
    # existuje, jen ji otevřená data nevydávají jako text. Ověřeno 8/2026.
    #
    # 💡 Rozdíl „prázdné" vs. „je to jinde" musí být v souboru VIDĚT, jinak z něj někdo v dobré
    # víře vyvodí, že formulář neexistuje.
    $t = [regex]::Replace($t, '<img[^>]*>', {
        param($m)
        $soubor = ([regex]::Match($m.Value, 'alt="([^"]*)"')).Groups[1].Value
        $zdroj  = ([regex]::Match($m.Value, 'src="([^"]*)"')).Groups[1].Value
        $popis  = @($soubor, $zdroj | Where-Object { $_ }) -join ' — '
        if ($popis) { "[vložený dokument, v otevřených datech není jako text: $popis]" }
        else { '[vložený dokument, v otevřených datech není jako text]' }
    })

    $t = $t -replace '<[^>]+>', ''

    # ⛔ ENTITY SE DEKÓDUJÍ AŽ TEĎ, PO ořezání značek (ověřeno 8/2026). Kdyby se dekódovaly dřív,
    # z `&lt;` by vznikl `<` a ořez značek by ho spolkl i s kusem věty za ním.
    #
    # ⚠️ Není to kosmetika — `&lt;` a `&gt;` jsou v právním textu MATEMATICKÉ OPERÁTORY. V příloze
    # zákona 592/1992 stálo v souboru „Je-li k &gt; 1" a „Q &lt; 0,0005" tam, kde zákon říká
    # „k > 1" a „Q < 0,0005". Táž třída chyby jako záměna α(I) za α(i): vzorec vypadá skoro
    # správně a nedá se přečíst.
    $t = [System.Net.WebUtility]::HtmlDecode($t)

    # 💡 Nezlomitelná mezera na obyčejnou. Zdroj ji používá jako sazbu („16.&nbsp;září"), ale
    # v souboru, který se čte grepem, je to past: vypadá jako mezera a nechová se jako mezera.
    # Slova se tím nemění, jen typografický pokyn — na rozdíl od `<`, který se zachovává.
    $t = $t -replace [char]0x00A0, ' '

    # Ořezat KAŽDÝ řádek, ne jen celek: zdroj píše „…EHS.<br/> Směrnice…" a po záměně za konec
    # řádku by z té mezery byl vedoucí odsazovací znak na každém pokračovacím řádku.
    return (($t -split "`n" | ForEach-Object { $_.Trim() }) -join "`n").Trim()
}

# ⛔ VŠECHNO, NEBO NIC. Když jediný znak markeru horní index v Unicodu nemá, vrátí se celý
# marker nezměněný. Půl markeru nahoře a půl dole je horší než celý dole: „hodnoty⁷e⁾" vypadá
# jako překlep, kdežto „hodnoty7e)" je aspoň poctivě obyčejný text.
# (Naběhlo to hned při prvním běhu — `10a)` se převedlo, `7e)` ne, protože mapa měla „a" a ne „e".)
#
# ⚠️ Unicode nemá horní index pro „q". Pro poznámky pod čarou to nevadí, ale pravidlo výš
# zaručuje, že by se takový marker jen nepřevedl — nikdy nezkomolil.

# ⛔ TABULKA SE MUSÍ PŘEVÉST, NE OŘEZAT (ověřeno 8/2026). Obecné `-replace '<[^>]+>'` slepí
# všechny buňky bez mezery — v příloze č. 2 ZDPH, což je seznam služeb se SNÍŽENOU SAZBOU, z toho
# vzniklo „CZ-CPAPopis služby36.00.2Úprava a rozvod vody prostřednictvím sítí.37Odvádění…".
# Kód od popisu nejde rozeznat a hranice řádků zmizí, takže se ze sazebníku nedá číst nic.
#
# ⚠️ Vyplavalo to teprve dneškem: obsah té přílohy se do souborů dostal až s opravou dobírání
# (dřív chyběl celý), takže to není stará vada, ale nedodělek té nové části.
#
# Emituje se Markdown tabulka. Vnitřní značky buněk se ZÁMĚRNĚ nechávají na pozdější krocích
# (`<sup>` v buňce se tak převede stejně jako jinde); jen `<br/>` uvnitř buňky se mění na mezeru,
# protože zalomení by rozbilo řádek tabulky.
function ConvertTo-Tabulka([string]$html) {
    $radky = @()
    $hlavicka = $null
    foreach ($tr in [regex]::Matches($html, '(?s)<tr[^>]*>(.*?)</tr>')) {
        $bunky = @()
        $jeHlavicka = $false
        foreach ($td in [regex]::Matches($tr.Groups[1].Value, '(?s)<t([hd])[^>]*>(.*?)</t\1>')) {
            if ($td.Groups[1].Value -eq 'h') { $jeHlavicka = $true }
            $obsah = $td.Groups[2].Value -replace '<br\s*/?>', ' '
            $bunky += (($obsah -replace '\s+', ' ').Trim() -replace '\|', '\|')
        }
        if ($bunky.Count -eq 0) { continue }
        $radky += '| ' + ($bunky -join ' | ') + ' |'
        # Oddělovač se vkládá jen jednou, hned za prvním řádkem z <th> — bez něj to Markdown
        # jako tabulku nevykreslí.
        if ($jeHlavicka -and -not $hlavicka) {
            $hlavicka = $true
            $radky += '|' + (' --- |' * $bunky.Count)
        }
    }
    if ($radky.Count -eq 0) { return $html }
    return "`n" + ($radky -join "`n") + "`n"
}

# ⛔ MAPA MUSÍ BÝT CASE-SENSITIVE. Obyčejný `@{}` hashtable v PowerShellu porovnává klíče BEZ
# ohledu na velikost písmen, takže `$mapa['I']` sáhne na položku `'i'` a vrátí `ⁱ` — velké
# písmeno se tiše změní na malé. V příloze zákona 592/1992 to udělalo z „αi(I)" → „αi⁽ⁱ⁾",
# a `α(I)` s `α(i)` jsou v tom vzorci dvě různé věci (odhaleno 24.8.2026 kontrolou, že stará
# verze je celá obsažená v nové — běžný diff by to ukázal jen jako „řádek se změnil").
#
# 💡 Velká písmena v mapě SCHVÁLNĚ NEJSOU: Unicode pro ně horní index skoro nemá. Díky pravidlu
# „všechno, nebo nic" tím marker s velkým písmenem zůstane celý obyčejný — což je správně.
function ConvertTo-HorniIndex([string]$s) {
    $mapa = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    @{
        '0' = '⁰'; '1' = '¹'; '2' = '²'; '3' = '³'; '4' = '⁴'; '5' = '⁵'
        '6' = '⁶'; '7' = '⁷'; '8' = '⁸'; '9' = '⁹'
        '(' = '⁽'; ')' = '⁾'; '+' = '⁺'; '-' = '⁻'
        'a' = 'ᵃ'; 'b' = 'ᵇ'; 'c' = 'ᶜ'; 'd' = 'ᵈ'; 'e' = 'ᵉ'; 'f' = 'ᶠ'; 'g' = 'ᵍ'
        'h' = 'ʰ'; 'i' = 'ⁱ'; 'j' = 'ʲ'; 'k' = 'ᵏ'; 'l' = 'ˡ'; 'm' = 'ᵐ'; 'n' = 'ⁿ'
        'o' = 'ᵒ'; 'p' = 'ᵖ'; 'r' = 'ʳ'; 's' = 'ˢ'; 't' = 'ᵗ'; 'u' = 'ᵘ'; 'v' = 'ᵛ'
        'w' = 'ʷ'; 'x' = 'ˣ'; 'y' = 'ʸ'; 'z' = 'ᶻ'
    }.GetEnumerator() | ForEach-Object { $mapa[$_.Key] = $_.Value }

    $znaky = $s.Trim().ToCharArray()
    if ($znaky.Count -eq 0) { return $s }
    foreach ($z in $znaky) { if (-not $mapa.ContainsKey([string]$z)) { return $s } }
    return -join ($znaky | ForEach-Object { $mapa[[string]$_] })
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outFile = Join-Path $OutDir "$Rok-$Cislo-$Zneni.md"

$sb = [System.Text.StringBuilder]::new()
# ⛔ „Předpis", ne „Zákon" (ověřeno 8/2026). Do dneška tu stálo natvrdo „Zákon č.",
# takže se ze souboru s vyhláškou 457/2020 Sb. — což je VYHLÁŠKA o formulářových podáních —
# stal „Zákon č. 457/2020 Sb.". Bylo to naše tvrzení, ne údaj z dat: uzel právního aktu nese
# jen `citace-právního-aktu` („457/2020 Sb."), typ v metadatech NENÍ.
#
# 💡 Odvozovat typ z větve `prefix` (kde doslova stojí „ZÁKON" / „VYHLÁŠKA") by šlo, ale stálo by
# to na pořadí fragmentů — a mýlit se v typu předpisu je přesně ta chyba, kterou tu opravujeme.
# Druh je navíc vidět hned v prvních řádcích dokumentu pod hlavičkou, takže se o nic nepřichází.
# ⛔ `0000-00-00` NENÍ DATUM (ověřeno 8/2026). Takhle e-Sbírka označuje
# VYHLÁŠENÉ ZNĚNÍ — text, jak vyšel ve Sbírce. U sdělení ministerstev je to jediné znění, které
# existuje: nekonsolidují se, protože se nenovelizují. Šablona to do té doby tiskla jako datum
# a v souboru stálo „znění účinné od 0000-00-00".
$popisZneni = if ($Zneni -eq '0000-00-00') { 'vyhlášené znění' } else { "znění účinné od $Zneni" }

[void]$sb.AppendLine("# Předpis č. $Cislo/$Rok Sb. — $popisZneni")
[void]$sb.AppendLine()

# ⚠️ Debata 6. 8. 2026  budoucí znění ukládat NECHTĚLA právě proto, že „vedle platného
# by se s ním do měsíce spletlo". Ukládá se, protože bez něj nejde odpovědět „co se změní",
# ale ta obava je oprávněná — proto to musí být vidět hned v prvním řádku, ne v metadatech.
if ($Zneni -gt (Get-Date -Format 'yyyy-MM-dd')) {
    [void]$sb.AppendLine("> # ⛔ TOTO ZNĚNÍ JEŠTĚ NENÍ ÚČINNÉ")
    [void]$sb.AppendLine("> ")
    [void]$sb.AppendLine("> Nabude účinnosti **$Zneni**. **Necituj ho jako platné právo.**")
    [void]$sb.AppendLine("> Je tu jen proto, aby šlo dopředu zjistit, co se změní — porovnej ho")
    [void]$sb.AppendLine("> se zněním účinným dnes.")
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("> ⚠️ **Generováno, needitovat ručně.** Stáhlo ``tools/zakony/fetch-zakon.ps1``")
[void]$sb.AppendLine("> z otevřených dat e-Sbírky $(Get-Date -Format 'd. M. yyyy').")
[void]$sb.AppendLine("> ")
[void]$sb.AppendLine("> ELI: ``eli/cz/sb/$Rok/$Cislo/$Zneni``")
[void]$sb.AppendLine("> Seznam znění: <$akt>")
[void]$sb.AppendLine("> ")
[void]$sb.AppendLine("> Rozdíl proti jinému znění: stáhni ho taky a udělej ``git diff --no-index``")
[void]$sb.AppendLine("> mezi oběma soubory. **Tím se poznají i nově přidané odstavce**, což je")
[void]$sb.AppendLine("> přesně to, co výňatek z principu neumí.")
[void]$sb.AppendLine()

foreach ($row in $sorted) {
    if (-not $row.text) { continue }   # strukturní uzel bez textu — do souboru nepatří
    $clean = ConvertTo-CistyText $row.text.value
    if (-not $clean) { continue }
    [void]$sb.AppendLine($clean)
    [void]$sb.AppendLine()
}

[System.IO.File]::WriteAllText($outFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

"Zapsáno: $outFile  ($($sorted.Count) fragmentů)"
