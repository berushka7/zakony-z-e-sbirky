---
name: zakony-z-e-sbirky
description: Stažení textu českého právního předpisu z otevřených dat e-Sbírky a zjištění, jestli se konkrétní ustanovení mezi zněními změnilo. Použij, když potřebuješ citovat český zákon, vyhlášku, nařízení vlády nebo sdělení, ověřit znění platné v konkrétním roce, nebo doložit původ nějaké konstanty (sazba, práh, lhůta). Spouštěč: „co říká § …", „platilo to i v roce …", „odkud je tahle částka", „stáhni zákon".
---

# Text českého předpisu z e-Sbírky

⛔ **Necituj český právní předpis z paměti.** `zakonyprolidi.cz` i `e-sbirka.gov.cz` vracejí
robotům 403, takže si to nemůžeš ověřit — a přeříkané znění bývá špatně. Doložený případ: model
při shrnování udělal z „poměrně" → „proporčně" a z „jedná se" → „jde se". U právního textu je
i překlep v jednom slově chyba.

## Postup

Skripty leží vedle tohohle souboru, ne v projektu — proto se volají přes `${CLAUDE_SKILL_DIR}`,
který Claude Code nahradí adresářem skillu, ať je nainstalovaný kdekoli. ⚠️ **Pracovní adresář
neměň:** znění se ukládají do `zneni/` v projektu, ze kterého se ptáš, ne vedle skriptu.
Vyžaduje **PowerShell 7+** (`pwsh`).

```powershell
# 1) jaká znění předpis má
& "${CLAUDE_SKILL_DIR}/fetch-zakon.ps1" -Rok 2004 -Cislo 235

# 2) stáhnout to, které tě zajímá
& "${CLAUDE_SKILL_DIR}/fetch-zakon.ps1" -Rok 2004 -Cislo 235 -Zneni 2026-01-01

# 3) platilo to ustanovení stejně i dřív?
& "${CLAUDE_SKILL_DIR}/porovnat-paragraf.ps1" -Rok 1997 -Cislo 48 -Fragment par_9-odst_2
```

💡 **Má projekt pro znění vlastní místo?** Předej ho parametrem `-OutDir <cesta>`; u `-Check`
je to táž složka, kterou má projít.

💡 **Krok 3 nahrazuje stahování.** Když jde jen o to, „změnilo se to?", nestahuj celý zákon —
48/1997 má 94 znění a 1 634 fragmentů, kdežto § 9 odst. 2 jsou dvě věty.

## ⛔ Čti, než začneš vyvozovat

**Prázdný výsledek NENÍ důkaz prázdna.** Před endpointem sedí WAF, který blokuje podle frekvence
i podle obsahu dotazu, a umí vrátit i platnou odpověď s nula řádky. **Vždycky ověř pozitivní
kontrolou** — týmž dotazem na místo, kde odpověď znáš. Bez ní neprohlašuj „ustanovení tam není".

**Nečti ustřižený výstup jako fakt.** Doložený případ: `cut -c1-175` uřízlo § 14 odst. 5 zákona
589/1992 hned za slovy „činí nejméně 30 % průměrné mzdy" — jenže věta pokračuje „…v roce 2024,
35 % v roce 2025 a 40 % od roku 2026". Kdo přečte jen začátek, prohlásí správnou hodnotu za chybu.
**U prahů a sazeb čti odstavec celý.**

**Znění ≠ dnešek.** Konstanta klíčovaná rokem se musí ověřit proti znění platnému v TOM roce.
Ustanovení se mění i uprostřed roku: § 14 odst. 5 zák. 589/1992 se k 1. 7. 2026 změnil tak, že
rok 2026 není jedno číslo.

## Jak dohledat identifikátor fragmentu

Parametr `-Fragment` je část URL za `#`, například `par_9-odst_2`, `par_14-odst_5`,
`par_101e-odst_1`. Bere se jako předpona, takže `par_9` vypíše i všechny odstavce. Podívej se do
staženého souboru nebo do URL na webu e-Sbírky.

## Co z toho NEVYVOZUJ

- **Sazba nebo práh nemusí být v zákoně.** Limit 10 000 Kč pro členění kontrolního hlášení
  v zákoně o DPH není vůbec — předepisují ho pokyny k formuláři. Když číslo v textu nenajdeš,
  neznamená to, že je špatně; znamená to, že zdroj je jinde.
- **Částka může být vyhlašovaná, ne stanovená.** Minimální mzdu vyhlašuje sdělení ministerstva,
  ne nařízení vlády. Průměrnou mzdu určuje nařízení vlády každý rok nové, s novým číslem.
- **Ověřuj i citace, které už v kódu jsou.** Chybějící odkaz je vidět, špatný ne — „§ 101c ZDPH"
  vypadá jako hotová práce, přitom je to úplně jiné ustanovení.
