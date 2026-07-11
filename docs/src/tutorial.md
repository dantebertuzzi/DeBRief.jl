# [Tutorial for beginners](@id tutorial)

This page assumes **no prior experience** with Julia or with data analysis.
By the end you will have real crime statistics on your screen, a chart, and
a spreadsheet file you can open in Excel.

## 1. Install Julia and the package

Download Julia from [julialang.org/downloads](https://julialang.org/downloads/)
and install it like any other program. Open it — you will see the *REPL*, an
interactive prompt where you type commands:

```
julia>
```

Type `]` (a closing bracket). The prompt changes to `pkg>` — this is the
package manager. Install DeBRief:

```
pkg> add DeBRief
```

Press backspace to return to the `julia>` prompt. Installation happens once;
from now on you only *load* the package:

```julia
using DeBRief
```

## 2. Your first data fetch

Ask for intentional homicides ("homicídio doloso") in Pernambuco in 2023:

```julia
df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso")
```

The first time, DeBRief downloads the official government spreadsheet for
2023 (you will see progress messages) and saves it on your disk. Type `df`
and press Enter to look at the result — a table where **each row is one
municipality, in one month, for one indicator**:

```
 Row │ date        state  municipality  typology          ⋯  value  female  male ⋯
     │ 2023-01-01  PE     ABREU E LIMA  Homicídio doloso  ⋯      3       0     3
     │ 2023-01-01  PE     AFOGADOS ...  Homicídio doloso  ⋯      1       0     1
```

What the columns mean, in plain words:

| Column | Meaning |
|:---|:---|
| `date` | the month (always shown as its first day) |
| `state` | two-letter state code (`"PE"` = Pernambuco) |
| `municipality` | the city, written as the government writes it (ALL CAPS) |
| `typology` | which indicator this row counts |
| `category` | a broader grouping (deaths, drugs, fire department…) |
| `measure` | the **unit**: `:victims` (people), `:occurrences` (police records), `:kg` (kilograms seized)… |
| `value` | the number itself, in the unit given by `measure` |
| `female` / `male` / `unspecified` | victims by sex, where the source reports it |

!!! tip "You can type it the lazy way"
    Filters ignore capitalization and accents: `"homicidio doloso"`,
    `"HOMICÍDIO DOLOSO"` and `"Homicídio Doloso"` all work. If you misspell
    an indicator, the error message lists every valid option. To see the
    list upfront: `typologies()`.

## 3. Answer a real question

*"How many homicide victims did Petrolina have in 2023, month by month?"*

```julia
using DataFrames   # ferramentas de tabela (instale com: ] add DataFrames)

petrolina = fetch_vde(state = "PE", municipality = "Petrolina",
                      year = 2023, typology = "homicídio doloso")

select(petrolina, :date, :value)    # só as colunas que interessam
sum(petrolina.value)                # total do ano
```

*"And which city in Pernambuco had the highest rate per 100 thousand
inhabitants?"* Add `relative = true` and DeBRief fetches official IBGE
population estimates and computes the rate for you:

```julia
pe = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso",
               granularity = :year, relative = true)

sort(select(pe, :municipality, :value, :rate_100k), :rate_100k, rev = true)
```

`granularity = :year` sums the twelve months into one row per city, and
`rate_100k` is deaths per 100,000 residents — the standard way to compare
cities of different sizes.

## 4. Make a chart

```julia
using CairoMakie   # gráficos (instale com: ] add CairoMakie)

mensal = combine(groupby(petrolina, :date), :value => sum => :vitimas)
lines(mensal.date, mensal.vitimas;
      axis = (title = "Homicídios em Petrolina, 2023",
              xlabel = "mês", ylabel = "vítimas"))
```

## 5. Save to a file you can open in Excel

```julia
using CSV          # instale com: ] add CSV
CSV.write("petrolina_2023.csv", petrolina)
```

## 6. Things that surprise first-time users

- **The first fetch is slow; later ones are fast.** Spreadsheets are cached
  on disk. [`cache_info`](@ref) shows what is stored and how many megabytes
  it takes; [`clear_cache`](@ref) deletes everything.
- **Asking for everything is heavy.** `fetch_vde()` with no filters returns
  every city × month × indicator since 2015 — millions of rows, several
  minutes of processing. Start filtered.
- **City names repeat across Brazil.** "Bom Jesus" exists in five states.
  Combine `municipality` with `state`, or pass the 7-digit IBGE code, to be
  unambiguous.
- **Zeros are real rows.** Recent years report the full panel, including
  months with zero cases — good news for statistics, since absence of crime
  is information too.
- **Your numbers may not match a state secretariat's website.** Different
  collection moments and indicator definitions (e.g. "CVLI" is a composite).
  See [Data harmonization](@ref) before comparing.
