"""
VetLIMS

This package contains functionality for parsing sample information from VetLIMS.
To use it, export data to a CSV containing a minimal set of rows (see the constant
`NEEDED_ROWS`).
"""
module VetLIMS

using Dates
using CSV

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
"""
struct SampleNumber
    num::UInt16
    subnum::UInt16
end

SampleNumber(x::Integer) = SampleNumber(UInt16(x), 0)

function parse_dot(::Type{SampleNumber}, s::Union{String, SubString{String}})
    str = strip(s)
    p = findfirst(isequal(UInt8('.')), codeunits(str))
    return if p === nothing
        SampleNumber(parse(UInt16, str), 0)
    else
        SampleNumber(
            parse(UInt16, view(str, 1:prevind(str, p))),
            parse(UInt16, view(str, p+1:lastindex(str)))
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

julia> VNumber("V000012345") == VNumber(12345)
true
"""
struct VNumber
    x::UInt32
    
    function VNumber(x::Integer)
        ux = UInt32(x)
        if ux > UInt32(999_999_999)
            throw(DomainError("Must be at most 9 digits", x))
        end
        new(ux)
    end
end

function VNumber(s::Union{String, SubString{String}})
    if ncodeunits(s) != 10 || codeunit(s, 1) != UInt8('V')
        error("Invalid VNumber: \"", s, '"')
    end
    VNumber(parse(UInt32, view(s, 2:10)))
end

Base.print(io::IO, v::VNumber) = print(io, 'V' * string(v.x, pad=9))
Base.show(io::IO, v::VNumber) = print(io, summary(v), "(\"", string(v), "\")")

"""
    SagsNumber(s::AbstractString)

Case number in VetLIMS. Identified by a 5-digit number followed by a 6-digit
alphanumeric code. Instantiate it from a string with the format in the example, or
from two numbers:

# Example
```julia
julia> SagsNumber("SAG-01234-890AKM")
SagsNumber("SAG-01234-890AKM")

julia> SagsNumber(1234, 498859654) # base 36
SagsNumber("SAG-01234-890AKM")
```
"""
struct SagsNumber
    numbers::UInt32
    letters::UInt32

    function SagsNumber(n::Integer, l::Integer)
        un, ul = UInt32(n), UInt32(l)
        if un > UInt32(99999)
            throw(DomainError("Must be at most 5 digits", un))
        elseif ul > 0x81bf0fff
            throw(DomainError("Must be at most \"ZZZZZZ\" base 36", ul))
        end
        new(un, ul)
    end
end

function SagsNumber(s::Union{String, SubString{String}})
    if ncodeunits(s) != 16 || !startswith(s, "SAG-") || codeunit(s, 10) != UInt8('-')
        error("Invalid SagsNumber: \"", s, '"')
    end
    numbers = parse(UInt32, view(s, 5:9))
    letters = parse(UInt32, view(s, 11:16), base=36)
    SagsNumber(numbers, letters)
end
SagsNumber(s::AbstractString) = SagsNumber(convert(String, s))

matchnumber(s::SagsNumber, n::Integer) = s.numbers == n

function Base.print(io::IO, x::SagsNumber)
    print(io, "SAG-" * string(x.numbers, pad=5) * '-' * uppercase(string(x.letters, base=36, pad=6)))
end
Base.show(io::IO, x::SagsNumber) = print(io, summary(x), "(\"", string(x), "\")")

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
function lims_rows(
    io::IO,
    delim=';',
    decimal=','
)
    csv = CSV.File(io,
        decimal=decimal,
        delim=delim,
        strict=true,
        lazystrings=true,
        dateformats=Dict(
            Symbol("(Skal ikke ændres) Ændret")  => DATETIME_FORMAT,
            :Oprettet => DATETIME_FORMAT,
            :Modtagelsestidspunkt => DATETIME_FORMAT,
            :Udtagelsesdato => DATE_FORMAT,
        )
    )
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
    vnum = VNumber(row[getproperty(namemap, Symbol("Internt nr."))])
    sag = SagsNumber(row[getproperty(namemap, Symbol("Sags ID"))])
    material = let
        v = row[namemap.Materiale]
        ismissing(v) ? nothing : parse(Material, v)
    end
    host = let
        v = row[namemap.Dyreart]
        ismissing(v) ? nothing : parse(Host, v)
    end
    receivedate = row[namemap.Modtagelsestidspunkt]
    sampledate = let
        v = row[namemap.Udtagelsesdato]
        ismissing(v) ? nothing : v
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
    VNumber,
    danish,
    english,
    LIMSRow,
    lims_rows

end # module