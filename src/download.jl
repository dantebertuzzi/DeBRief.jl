# Camada de download: Downloads.jl (stdlib) com retomada via header Range,
# retry com backoff exponencial e verificação de integridade — os servidores
# Plone do gov.br frequentemente derrubam a conexão no meio de arquivos
# grandes (SSL "unexpected eof") e ocasionalmente devolvem páginas de erro
# pequenas com status 200.

"""
    DownloadConfig(; retries = 5, timeout = 900, min_size = 1_024,
                     progress = true)

Configuration for the download layer: number of `retries`, per-request
`timeout` (seconds), `min_size` below which a response is treated as a
server error page, and whether to print `progress` messages. Internal.
"""
Base.@kwdef struct DownloadConfig
    retries::Int = 5
    timeout::Int = 900
    min_size::Int = 1_024
    progress::Bool = true
end

# XLSX é um zip: os dois primeiros bytes devem ser "PK". Pega tanto páginas
# de erro salvas como .xlsx quanto corrupção grosseira.
function _looks_valid(path::AbstractString)
    endswith(lowercase(path), ".xlsx") || return true
    open(path, "r") do io
        magic = read(io, 2)
        return magic == UInt8['P', 'K']
    end
end

"""
    _download(url, dest; cfg = DownloadConfig()) -> String

Download `url` into `dest` atomically, retrying up to `cfg.retries` times
with exponential backoff. Interrupted transfers are RESUMED from the partial
`dest * ".part"` file via an HTTP `Range` header (the gov.br servers often
drop long connections mid-body), including across separate calls. Returns
`dest`. Internal helper.
"""
function _download(url::AbstractString, dest::AbstractString;
                   cfg::DownloadConfig = DownloadConfig())
    tmp = dest * ".part"
    lasterr = nothing
    for attempt in 1:cfg.retries
        try
            offset = isfile(tmp) ? filesize(tmp) : 0
            if cfg.progress
                extra = offset > 0 ? " — resuming at $(round(offset / 2^20, digits = 1)) MiB" : ""
                @info "DeBRief: downloading $(basename(dest)) (attempt $attempt/$(cfg.retries))$extra"
            end
            headers = offset > 0 ? ["Range" => "bytes=$(offset)-"] : Pair{String,String}[]
            io = open(tmp, offset > 0 ? "a" : "w")
            resp = try
                Downloads.request(url; method = "GET", output = io,
                                  headers, timeout = cfg.timeout, throw = true)
            finally
                close(io)
            end
            if offset > 0 && resp.status == 200
                # Servidor ignorou o Range e mandou o arquivo inteiro de novo,
                # anexado ao parcial -> descarta e recomeça do zero
                rm(tmp; force = true)
                error("server ignored the Range header; restarting from scratch")
            end
            resp.status in (200, 206) ||
                error("unexpected HTTP status $(resp.status)")
            filesize(tmp) >= cfg.min_size ||
                error("downloaded file is suspiciously small ($(filesize(tmp)) bytes)")
            if !_looks_valid(tmp)
                rm(tmp; force = true)  # provável página de erro; não retomar disso
                error("downloaded file is not a valid XLSX (bad magic bytes)")
            end
            mv(tmp, dest; force = true)
            return dest
        catch err
            lasterr = err
            # NÃO apaga o .part: a próxima tentativa (ou a próxima chamada)
            # retoma de onde a conexão caiu
            attempt < cfg.retries && sleep(min(2.0^attempt, 30.0))
        end
    end
    error("DeBRief: failed to download $url after $(cfg.retries) attempts " *
          "(partial file kept for resume; just call the fetch again). " *
          "Last error: $(sprint(showerror, lasterr))")
end

"""
    _ensure_file(url, parts...; refresh = false, progress = true,
                 min_size = 1_024) -> String

Return the cached path for `parts`, downloading from `url` first when the
file is absent or `refresh = true`. Internal helper.
"""
function _ensure_file(url::AbstractString, parts::AbstractString...;
                      refresh::Bool = false, progress::Bool = true,
                      min_size::Integer = 1_024)
    dest = cache_path(parts...)
    if refresh
        # Recomeço explícito: invalida também qualquer parcial antigo
        rm(dest * ".part"; force = true)
    end
    if refresh || !isfile(dest)
        _download(url, dest; cfg = DownloadConfig(; progress, min_size = Int(min_size)))
    end
    return dest
end
