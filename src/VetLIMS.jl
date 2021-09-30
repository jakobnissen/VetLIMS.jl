"""
VetLIMS

This package contains functionality for parsing sample information from VetLIMS.
To use it, export data to a CSV containing a minimal set of rows (see the constant
`NEEDED_ROWS`).
"""
module VetLIMS

using Dates
using CSV

const UTF8 = Union{String, SubString{String}}
const DATETIME_FORMAT = dateformat"dd/mm/yyyy HH.MM"
const DATE_FORMAT = dateformat"dd/mm/yyyy"

"Columns from CSV file exported from VetLIMS. To be parsed correctly to `LIMSRow`,
the CSV file must contain these columns at minimum."
const NEEDED_COLUMNS = Set([
    Symbol("Prøve id"),
    Symbol("Internt nr."),
    Symbol("Sags ID"),
    :Materiale,
    :Dyreart,
    :Modtagelsestidspunkt,
    :Udtagelsesdato
])

struct Unsafe end

"Get the English name of the object, or `nothing` if not applicable"
function english end

"Get the Danish name of the object"
function danish end

# To create enums, we fetch a vector of (danish, english) names from VetLIMS,
# then we use to_symbol to create valid Julia symbols from the Danish names,
# then make sure there are not any valid duplicates.
# This function is then used to create the enums in their respective files.
function dedup_categories(v::Vector{Tuple{String, Union{Nothing, String}}})
    d = Dict{Symbol, Tuple{String, Union{Nothing, String}}}()
    for (da, en) in v
        sym = to_symbol(da)
        existing = get(d, sym, nothing)
        if existing !== nothing
            oldda, olden = existing
            if oldda == da && olden in (nothing, en)
                d[sym] = (da, en)
            else
                error("Duplicate symbol: \"", sym, '"')
            end
        else
            d[sym] = (da, en)
        end
    end
    return sort!([(k, v[1], v[2]) for (k, v) in d])
end

function to_symbol(s::String)
    v = Char[]
    for char in s
        if isletter(char) || isdigit(char)
            push!(v, char)
        elseif !isempty(v) && last(v) != '_'
            push!(v, '_')
        end
    end
    Symbol(join(v))
end

include("hosts.jl")
using .Hosts

include("materials.jl")
using .Materials

"""
    SampleNumber(x::Integer)

A struct that contains the sample number and subsample number. In e.g.
`SampleNumber(2, 1)`, the sample number is 1, and the subsample number is 1.
If the subsample number is 0, it is assumed to be inapplicable.

# Examples
```julia
julia> SampleNumber(4, 0) # zero-subsample is omitted
SampleNumber(4)
```
"""
struct SampleNumber
    num::UInt16
    subnum::UInt16
end

SampleNumber(x::Integer) = SampleNumber(UInt16(x), 0)

function parse_dot(::Type{SampleNumber}, s::UTF8)
    str = strip(s)
    p = findfirst(isequal(UInt8('.')), codeunits(str))
    return if p === nothing
        SampleNumber(parse(UInt16, str, base=10), 0)
    else
        SampleNumber(
            parse(UInt16, view(str, 1:prevind(str, p)), base=10),
            parse(UInt16, view(str, p+1:lastindex(str)), base=10)
        )
    end
end

function Base.show(io::IO, x::SampleNumber)
    print(io, summary(x), '(', x.num)
    if !iszero(x.subnum)
        print(io, ", ", x.subnum)
    end
    print(io, ')')
end

"""
    VNumber(x::Integer)

The internal number ("V-nummer") used by VetLIMS for samples. It is identified
by a 9-digit number.

```julia
julia> VNumber("V000012345") == VNumber(12345)
true
```
"""
struct VNumber
    x::UInt32

    VNumber(x::UInt32, ::Unsafe) = new(x)
end

function VNumber(x::Integer)
    ux = UInt32(x)
    if ux > UInt32(999_999_999)
        throw(DomainError("Must be at most 9 digits", x))
    end
    return VNumber(x, Unsafe())
end

Base.tryparse(::Type{VNumber}, s::AbstractString) = tryparse(VNumber, String(s))
function Base.tryparse(::Type{VNumber}, s::UTF8)
    if ncodeunits(s) != 10 || codeunit(s, 1) != UInt8('V')
        return nothing
    end
    n = tryparse(UInt32, view(s, 2:10), base=10)
    n === nothing && return nothing
    n > UInt32(999_999_999) && return nothing
    return VNumber(n, Unsafe())
end

function Base.parse(::Type{VNumber}, s::AbstractString)
    result = tryparse(VNumber, s)
    result === nothing && error("Invalid VNumber: \"", s, '"')
    return result
end

Base.print(io::IO, v::VNumber) = print(io, 'V' * string(v.x, pad=9))
Base.show(io::IO, v::VNumber) = print(io, "vnum\"", string(v), '"')

macro vnum_str(s)
    parse(VNumber, s)
end

"""
    SagsNumber

Case number in VetLIMS. Identified by a 5-digit number followed by a 6-digit
alphanumeric code. Instantiate it from a string with the format in the example, or
from two numbers:

# Example
```julia
julia> parse(SagsNumber, "SAG-01234-890AKM")
SagsNumber("SAG-01234-890AKM")

julia> SagsNumber(1234, 498859654) # base 36
SagsNumber("SAG-01234-890AKM")
```
"""
struct SagsNumberV1
    numbers::UInt32
    letters::UInt32

    SagsNumberV1(n::UInt32, L::UInt32, ::Unsafe) = new(n, L)
end

function SagsNumberV1(n::Integer, l::Integer)
    un, ul = UInt32(n), UInt32(l)
    if un > UInt32(99999)
        throw(DomainError("Must be at most 5 digits", un))
    elseif ul > 0x81bf0fff
        throw(DomainError("Must be at most \"ZZZZZZ\" base 36", ul))
    end
    SagsNumberV1(un, ul, Unsafe())
end

function Base.tryparse(::Type{SagsNumberV1}, s::UTF8)
    if ncodeunits(s) != 16 || !startswith(s, "SAG-") || codeunit(s, 10) != UInt8('-')
        return nothing
    end
    numbers = tryparse(UInt32, view(s, 5:9), base=10)
    numbers === nothing && return nothing
    numbers > UInt32(99999) && return nothing
    letters = tryparse(UInt32, view(s, 11:16), base=36)
    letters === nothing && return nothing
    letters > 0x81bf0fff && return nothing # ZZZZZZ base 36
    SagsNumberV1(numbers, letters, Unsafe())
end

function Base.print(io::IO, x::SagsNumberV1)
    print(io, "SAG-" * string(x.numbers, pad=5) * '-' * uppercase(string(x.letters, base=36, pad=6)))
end

struct SagsNumberV2
    year::UInt32
    numbers::UInt32

    SagsNumberV2(y::UInt32, n::UInt32, ::Unsafe) = new(y, n)
end

function SagsNumberV2(n::Integer, l::Integer)
    uy, un = UInt32(n), UInt32(l)
    if un > UInt32(99999)
        throw(DomainError("Must be at most 5 digits", un))
    elseif !in(uy, 2000:2100)
        throw(DomainError("Year must be in 2020:2100", uy))
    end
    SagsNumberV1(uy, un, Unsafe())
end

function Base.tryparse(::Type{SagsNumberV2}, s::UTF8)
    if ncodeunits(s) != 10 || codeunit(s, 5) != UInt8('-')
        return nothing
    end
    year = tryparse(UInt32, view(s, 1:4), base=10)
    year === nothing && return nothing
    year in 2000:2100 || return nothing
    numbers = tryparse(UInt32, view(s, 6:10), base=10)
    numbers === nothing && return nothing
    numbers > UInt32(99999) && return nothing
    SagsNumberV2(year, numbers, Unsafe())
end

function Base.print(io::IO, x::SagsNumberV2)
    print(io, string(x.year, pad=4) * '-' * string(x.numbers, pad=5))
end

const SagsNumber = Union{SagsNumberV1, SagsNumberV2}

function Base.tryparse(::Type{T}, s::AbstractString) where {T <: SagsNumber}
    tryparse(T, String(s))
end

function Base.parse(::Type{T}, s::AbstractString) where {T <: SagsNumber}
    result = tryparse(T, s)
    result === nothing && error("Invalid $T: \"", s, '"')
    return result
end

function Base.tryparse(::Type{SagsNumber}, s::UTF8)
    y = tryparse(SagsNumberV1, s)
    y === nothing || return y
    tryparse(SagsNumberV2, s)
end

macro sag_str(s)
    y = tryparse(SagsNumber, s)
    y === nothing ? error("Invalid SagsNumber: \"", s, "\"") : y
end

Base.show(io::IO, x::SagsNumber) = print(io, "sag\"", string(x), '\"')

"""
A struct containing the minimum relevant information about a sample needed for my
workflows. Created in bulk by using `lims_rows`. See that function and this struct's
fields for more details.
"""
struct LIMSRow
    samplenum::SampleNumber
    vnum::VNumber
    sag::SagsNumber
    sampledate::Union{Nothing, Date}
    material::Union{Nothing, Material}
    host::Host
    receivedate::DateTime
end

"""
    lims_rows(io::IO, [delim=';', decimal=','])

Create a `Vector{LIMSRow}` from the CSV file `io`. The CSV file must have the
columns at `NEEDED_COLUMNS` at minimum, in any order. Certain assumptions are made
about the format of columns. If these are violated, you probably need to review
the source code.
"""
function lims_rows(io::IO)
    csv = CSV.File(io, strict=true, types=String)
    if !issubset(NEEDED_COLUMNS, propertynames(csv))
        error("Found wrong columns, expected $(sort(collect(NEEDED_COLUMNS)))")
    end

    # By first making a map from column names to column number, then passing it
    # to the actual parsing function, this code becomes robust against changes in
    # the column order in the future, while remaining efficient. 
    namemap = (; ((sym, i) for (i, sym) in enumerate(propertynames(csv)))...)
    return map(row -> LIMSRow(row, namemap), csv)
end

function LIMSRow(row::CSV.Row, namemap::NamedTuple)
    samplenum = parse_dot(SampleNumber, row[getproperty(namemap, Symbol("Prøve id"))])
    vnum = parse(VNumber, row[getproperty(namemap, Symbol("Internt nr."))])
    sag = parse(SagsNumber, row[getproperty(namemap, Symbol("Sags ID"))])
    material = let
        v = row[namemap.Materiale]
        ismissing(v) ? nothing : parse(Material, v)
    end
    host = let
        v = row[namemap.Dyreart]
        ismissing(v) ? nothing : parse(Host, v)
    end
    receivedate = DateTime(row[namemap.Modtagelsestidspunkt], DATETIME_FORMAT)
    sampledate = let
        v = row[namemap.Udtagelsesdato]
        ismissing(v) ? nothing : Date(v, DATE_FORMAT)
    end
    LIMSRow(
        samplenum,
        vnum,
        sag,
        sampledate,
        material,
        host,
        receivedate,
    )
end

export Materials,
    Material,
    Hosts,
    Host,
    SampleNumber,
    SagsNumber,
    @sag_str,
    VNumber,
    @vnum_str,
    danish,
    english,
    LIMSRow,
    lims_rows

end # module
