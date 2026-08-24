# zakony-z-esbirky

Stažení úplného znění českého právního předpisu z **otevřených dat e-Sbírky** do textového
souboru — a nástroj, který řekne, jestli se konkrétní ustanovení mezi zněními změnilo.

> ⚠️ **Neoficiální nástroj.** S provozovatelem e-Sbírky nemá nic společného; jen čte její veřejná
> otevřená data.

## Proč to existuje

`zakonyprolidi.cz` i `e-sbirka.gov.cz` vracejí robotům **403**. Skript, agent ani jazykový model
se tak k textu zákona nedostane — a citovat právo z paměti modelu je špatný nápad: při zkoušce
udělal shrnující model z „poměrně" → „proporčně" a z „jedná se" → „jde se". U právního textu je
i překlep v jednom slově chyba.

Otevřená data e-Sbírky 403 nevracejí a text v sobě mají. Cesta k němu je ale plná pastí, které
tenhle repozitář dokumentuje — **hodnota není ve dvou stech řádcích PowerShellu, ale v tom, co je
kolem nich.**

## Co to umí

```powershell
# jaká znění předpis má
.\fetch-zakon.ps1 -Rok 2004 -Cislo 235

# stáhnout konkrétní znění do zneni/2004-235-2026-01-01.md
.\fetch-zakon.ps1 -Rok 2004 -Cislo 235 -Zneni 2026-01-01

# nepřibylo u něčeho, co mám uložené, novější znění?
.\fetch-zakon.ps1 -Check

# změnilo se tohle ustanovení mezi zněními? (bez stahování čehokoli)
.\porovnat-paragraf.ps1 -Rok 1997 -Cislo 48 -Fragment par_9-odst_2
```

Vyžaduje **PowerShell 7+** (`pwsh`). Žádné závislosti, žádná registrace, žádný klíč.

## Proč celé znění, a ne výňatek

Výňatek neumí zachytit **nově přidaný odstavec**. Kontrola „citovaný text se nezměnil" pak dá
falešné zelené světlo přesně tam, kde je riziko. Se dvěma staženými zněními stačí `git diff`.

## ⛔ Co to stálo: pasti, na které se přijde až praxí

Tohle je vlastní obsah repozitáře. Všechno je ověřené na reálných předpisech (8/2026).

### Text visí i na uzlech, které nemají URL

Nadpis paragrafu a **návětí** (uvozující věta před výčtem písmen) jsou v datech samostatné uzly
**bez** `url-fragmentu-znění` — visí na paragrafu přes `má-předka`. Dotaz vázaný na tu URL je
nevrátí vůbec. V zákoně o DPH tak chybělo **271 nadpisů a návětí** a soubor přitom vypadal úplný.

⚠️ A jedna úroveň nestačí: **tělo závěrečného paragrafu visí až na vnukovi.** Proto tu jsou tři
průchody — hlavní, dobrání potomků a dobrání větví mimo `norma`.

### Dokument má víc větví než `norma`

`prefix` (vyhlašovací věta a název), `norma`, `postfix` (**podpisy**), `prilohy`,
`poznamkypodcarou`. Filtr na `#` je nepustí dovnitř, protože kořen URL s `#` nemá — bez toho
chybí **začátek i konec předpisu**, tedy i věta „Tento zákon nabývá účinnosti…".

### Řadicí klíč se v půli roku 2026 přejmenoval

`hierarchie-fragmentu-znění-právního-aktu` (cesta `/2/1/6/2/`) je u nově generovaných zněních
nahrazená `pořadí-fragmentu-znění-právního-aktu` (hex `6ADAF6BD60`). Starší znění nesou zatím
obojí. Hex klíč se řadí prostým porovnáním znaků — potomek prodlužuje předponu rodiče.

⚠️ Vypadalo to jako „část zákona zmizela". Nezmizela, jen se přejmenoval predikát.

### Před endpointem sedí WAF

Blokuje podle frekvence **i podle obsahu dotazu**. Řízená dvojice z téže IP v rozestupu vteřin,
jediný rozdíl je znak `#` v řetězci filtru: **s ním 403, bez něj 200 a data**. `#` ale není jediný
spouštěč. Tranzitivní cesta `má-předka+` nad celým předpisem vrací **502**, nad jedním uzlem
projde okamžitě.

⛔ **Prázdný výsledek proto není důkaz prázdna.** Ověřuj ho **pozitivní kontrolou** — týmž dotazem
na místo, kde odpověď znáš.

### Inline značky nesou význam

`<sup>` je odkaz na poznámku pod čarou, `<br/>` je zalomení, `<table>` je tabulka, `<img>` je
**vložený dokument** (příloha jako PDF). Obecné `-replace '<[^>]+>'` z nich udělá kaši:
`unie1)`, slepený seznam sedmi směrnic, `CZ-CPAPopis služby36.00.2Úprava…` a **prázdný nadpis
přílohy**, který se čte jako „příloha je prázdná".

⚠️ **Entity se dekódují až PO ořezání značek.** Kdyby dřív, z `&lt;` vznikne `<` a ořez ho spolkne
i s kusem věty. A nejsou to ozdoby — `&lt;` a `&gt;` jsou ve vzorcích a prazích **operátory**:
„pro napětí `&lt;= 1000 V`" je práh pro zařazení do odpisové skupiny.

### `0000-00-00` není datum

Takhle e-Sbírka označuje **vyhlášené znění**. U sdělení ministerstev je to jediné znění, které
existuje — nekonsolidují se, protože se nenovelizují.

### Velká písmena v názvu jsou sazba, ne obsah

Na webu svítí „O DANI Z PŘIDANÉ HODNOTY", ale v datech je `o dani z přidané hodnoty`. Verzálky
dělá `text-transform` v CSS. **Pětivteřinový test:** označ ten název na webu a zkopíruj —
do schránky padnou malá písmena.

⛔ „Srovnat to podle webu" by znamenalo dopsat do zákona znaky, které ve zdroji nejsou.

## Co to NEUMÍ

- **Neřeší přílohy vydané jako dokument** (PDF formuláře). Označí je, nestáhne.
- **Nezná pokyny a metodiky.** Spousta praktických pravidel není v zákoně, ale v pokynech
  k formulářům — ty tady nenajdeš.
- **Neposoudí, co ustanovení znamená.** Vrací text, ne výklad.
- **Nemá autoritu.** Autoritativní je Sbírka zákonů; tohle je kopie z otevřených dat.

## Licence

Skripty: MIT. **Stažené texty právních předpisů nejsou dílem tohoto repozitáře** — jsou to
otevřená data e-Sbírky a řídí se jejími podmínkami.
