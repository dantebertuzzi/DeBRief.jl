#!/usr/bin/env julia
#= scripts/testes/verifica_links.jl
Verifica se todos os links (HTTP/HTTPS/FTP) no README e nos arquivos .md da
documentação estão acessíveis. =#
using Downloads: download

const ROOT = dirname(dirname(@__DIR__))
const MD_ROOTS = [joinpath(ROOT, "README.md"), joinpath(ROOT, "docs")]

function extrai_urls(texto::String)
    urls = String[]
    for m in eachmatch(r"https?://[^\s\)\]\"\']+|ftp://[^\s\)\]\"\']+", texto)
        url = m.match
        url = replace(url, r"[\)\]\"\'\,\.\;]*$" => "")
        url = replace(url, r"`$" => "")
        push!(urls, url)
    end
    return unique(urls)
end

function verifica_url(url::String)
    try
        # timeout generoso: evita falso-negativo em portais gov.br que às
        # vezes respondem devagar a partir dos runners de CI.
        download(url; timeout=60)
        return (url, true, nothing)
    catch e
        return (url, false, sprint(showerror, e))
    end
end

function main()
    md_files = String[]
    for root in MD_ROOTS
        if isfile(root)
            push!(md_files, root)
        elseif isdir(root)
            for (dir, _, files) in walkdir(root)
                for f in files
                    endswith(f, ".md") && push!(md_files, joinpath(dir, f))
                end
            end
        end
    end
    @info "$(length(md_files)) arquivos .md encontrados"

    todas_urls = String[]
    for f in md_files
        texto = read(f, String)
        urls = extrai_urls(texto)
        append!(todas_urls, urls)
    end
    unique!(todas_urls)
    @info "$(length(todas_urls)) URLs únicas encontradas"

    # só verifica URLs externas (não links internos tipo #anchor)
    externas = filter(u -> !startswith(u, "#"), todas_urls)
    @info "Verificando $(length(externas)) URLs externas..."

    problemas = []
    for (i, url) in enumerate(externas)
        _, ok, err = verifica_url(url)
        simbolo = ok ? "✓" : "✗"
        println("[$i/$(length(externas))] $simbolo $url")
        if !ok
            push!(problemas, (url, err))
        end
    end

    if isempty(problemas)
        println("\n✅ Todos os $(length(externas)) links estão acessíveis.")
    else
        println("\n❌ $(length(problemas)) link(s) quebrado(s):")
        for (url, err) in problemas
            println("  $url")
            println("    → $err")
        end
        exit(1)
    end
end

main()
