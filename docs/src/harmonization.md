# Data harmonization

DeBRief.jl normalizes two families of files published by the Brazilian
Ministry of Justice and Public Security (MJSP). This document records the
harmonization decisions so users can audit what the package does to the raw
data. Nothing here is silent: every transformation below is deterministic and
covered by offline tests against real-layout fixtures in `test/data/`.

## 1. Two sources, one methodological break — never merged

| | Classic Sinesp (`fetch_sinesp`) | Sinesp-VDE (`fetch_vde`) |
|---|---|---|
| Coverage | 2015–2022 | 2015–present |
| Granularity | state (UF), monthly | municipality, monthly |
| Indicators | 9 crime typologies | 28 indicators (Portaria MJSP 229/2018, Resolução ConSinesp 06) |
| Unit | occurrences only | victims, occurrences, kg, units, people, warrants, services |
| Collection | SinespJC / Sinesp Integração pipelines | Sinesp VDE (Validador de Dados Estatísticos), launched May 2023 with retro-published series from 2015 |

The two series overlap in 2015–2022 **and disagree** for overlapping
typologies, because the collection and validation pipelines differ. DeBRief
deliberately exposes them through two separate functions with distinct
schemas and does **not** splice them into a single continuous series. If you
need a long series crossing 2022/2023, you must decide yourself how to handle
the break (e.g., level-shift adjustment, dummy variables) — the package will
not decide for you.

Additionally, VDE numbers reflect each state's data-entry status at
extraction time and are revised retroactively; the MJSP republishes the
annual files. Use `refresh = true` (or `clear_cache()`) to pick up revisions.

## 2. Typology vocabulary (VDE)

The `evento` vocabulary drifts across annual files and diverges from the
normative names in Portaria 229/2018. DeBRief maps every variant to a single
canonical name via `DeBRief.VDE_ALIASES` (year-independent variants) and
`DeBRief.VDE_ALIASES_BY_YEAR` (year-specific overrides). Documented cases:

- Portaria says *"Apreensão de arma de fogo"*; the files say
  *"Arma de Fogo Apreendida"* → canonical: **Arma de Fogo Apreendida**
  (we keep the file vocabulary as canonical).
- Portaria says *"Homicídio na forma tentada"*; files say
  *"Tentativa de homicídio"* → canonical: **Tentativa de homicídio**.
- *"Tentativa de feminicídio"* only exists in recent files; it is part of the
  canonical vocabulary and simply absent in earlier years.
- Singular/plural drift (*"Roubo de veículos"*) is folded into the singular.

Unknown `evento` values (future indicators) are **not dropped**: they pass
through with `category = "other"` and a unit inferred from which value column
is populated, so a vocabulary change upstream degrades gracefully instead of
silently losing data.

## 3. Units of measure

The VDE mixes units across indicators. The output schema encodes this in the
`measure` column and reads `value` from the matching source column:

| `measure` | source column | indicators |
|---|---|---|
| `:victims` | `total_vitima` (fallback `total`) | homicide-family, rape, suicide, state agents |
| `:occurrences` | `total` | vehicle robbery/theft, cargo, banks, drug trafficking |
| `:kg` | `total_peso` | cocaine and marijuana seizures |
| `:units` | `total` | firearms seized |
| `:people` | `total` | missing/located persons |
| `:warrants` | `total` | arrest warrants served |
| `:services` | `total` | fire department indicators |

Comparing or summing `value` across different `measure`s is meaningless;
group by `measure` first.

**Column fallback for counts.** Real files are inconsistent about *which*
column carries the count for victim-type and missing-persons indicators: the
2025 files, for instance, publish `Pessoa Desaparecida`/`Pessoa Localizada`
with `total = 0` nationwide and the actual counts only in the by-sex columns.
For `:victims` and `:people`, DeBRief therefore takes the first non-missing,
non-zero value along the chain *target column → alternative column
(`total`/`total_vitima`) → sum of the by-sex columns*; when every candidate
is zero, zero is kept as the legitimate value. Rows disaggregated by age
group contribute their by-sex sums and are then aggregated per
municipality-month, which is correct as long as the age groups partition the
total (they do in the published files).

## 4. Row-level aggregation

The MJSP's own download page warns that *Tentativa de Homicídio* and
*Estupro* may appear as **two rows for the same municipality-month, which
must be summed**. DeBRief applies this aggregation generally, summing every
(municipality, month, typology) group. A consequence: the source's optional
breakdowns (`arma` for firearms, `faixa_etaria` for missing persons,
`agente` for state agents) are aggregated away — the v0.1.0 schema is strictly
municipality × month × typology. Exposing those breakdowns is a candidate for
a future minor release.

## 5. Municipality identification

VDE files carry **only municipality names**, no IBGE codes, and Brazilian
municipality names are not unique across states. DeBRief:

- filters names case- and accent-insensitively;
- warns when a name filter matches more than one state;
- accepts IBGE codes in `municipality` by resolving them through a registry
  derived from the IBGE/SIDRA municipal population table (cached on disk);
- resolves codes by normalized name + UF for the geo extension join, marking
  unresolved rows with `missing` geometry (name spelling in Sinesp files
  occasionally diverges from the IBGE registry).

## 6. Rates per 100k inhabitants

With `relative = true`, populations come from IBGE/SIDRA table 6579
(population estimates, variable 9324), state (`n3`) or municipality (`n6`)
level. Decisions:

- monthly rows use the **annual** population of the matching year — no
  monthly interpolation in v0.1.0 (tracked as a future issue);
- years without a published estimate (e.g. the 2022 census year) fall back to
  the nearest available year with a warning;
- rows whose population cannot be resolved get `rate_100k = missing` with a
  summary warning, never a silent zero.

## 7. Classic file quirks

- `UF` comes as the full state name → converted to the two-letter
  abbreviation;
- `Mês` comes as lowercase Portuguese month names → converted to month
  numbers;
- typology names match the nine canonical ones after accent/case folding.
