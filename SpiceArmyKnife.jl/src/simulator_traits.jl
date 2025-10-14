# SPICE Simulator Traits
#
# This file defines an abstract type hierarchy for SPICE simulators and trait functions
# for querying simulator-specific capabilities. This allows dialect conversion to be
# based on simulator features rather than hard-coded dialect names.
#
# Design Philosophy:
# - Each simulator is represented by a concrete type (Ngspice, Xyce, Pspice, etc.)
# - Trait functions provide boolean queries for simulator capabilities
# - Default implementations provide sensible defaults
# - Specific simulators override traits as needed
#
# Example:
# ```julia
# # Check if simulator supports documentation properties
# if hasdocprops(Hspice())
#     # Include doc props in output
# end
# ```

# =============================================================================
# Abstract Type Hierarchy
# =============================================================================

"""
    AbstractSimulator

Base abstract type for all circuit simulators.
All simulator types should inherit from this.
"""
abstract type AbstractSimulator end

"""
    AbstractSpiceSimulator <: AbstractSimulator

Base type for SPICE-family simulators.
These simulators use SPICE netlist syntax.
"""
abstract type AbstractSpiceSimulator <: AbstractSimulator end

"""
    AbstractSpectreSimulator <: AbstractSimulator

Base type for Spectre-family simulators.
These simulators use Spectre netlist syntax.
"""
abstract type AbstractSpectreSimulator <: AbstractSimulator end

# =============================================================================
# Concrete Simulator Types
# =============================================================================

# SPICE simulators
"""
    Ngspice <: AbstractSpiceSimulator

Ngspice - open source SPICE simulator.
Does NOT support documentation-only parameters like iave, vpk, mfg, type, etc.
"""
struct Ngspice <: AbstractSpiceSimulator end

"""
    Hspice <: AbstractSpiceSimulator

Synopsys HSPICE - commercial SPICE simulator with extended syntax.
Supports documentation-only parameters.
"""
struct Hspice <: AbstractSpiceSimulator end

"""
    Pspice <: AbstractSpiceSimulator

PSpice - commercial SPICE simulator from Cadence.
Supports documentation-only parameters.
"""
struct Pspice <: AbstractSpiceSimulator end

"""
    Xyce <: AbstractSpiceSimulator

Xyce - open source parallel SPICE simulator from Sandia National Labs.
"""
struct Xyce <: AbstractSpiceSimulator end

# Spectre simulators
"""
    SpectreADE <: AbstractSpectreSimulator

Cadence Spectre - commercial circuit simulator with its own netlist syntax.
"""
struct SpectreADE <: AbstractSpectreSimulator end

# =============================================================================
# Language Trait
# =============================================================================

"""
    language(::AbstractSimulator) -> Symbol

Returns the netlist language used by the simulator (`:spice` or `:spectre`).
"""
language(::AbstractSpiceSimulator) = :spice
language(::AbstractSpectreSimulator) = :spectre

# =============================================================================
# Documentation Property Trait
# =============================================================================

"""
    hasdocprops(simulator::AbstractSimulator) -> Bool

Returns true if the simulator supports documentation-only model parameters.

Documentation parameters are metadata fields like:
- `iave`: Average current
- `vpk`: Peak voltage
- `mfg`: Manufacturer code
- `type`: Device type description
- `icrating`: Current rating
- `vceo`: Collector-emitter voltage

These parameters document the device but don't affect simulation.
Ngspice does NOT recognize these and will error if they are present.
HSPICE and PSpice support them.

Default: false (most simulators don't support doc props)
"""
hasdocprops(::AbstractSimulator) = false

# HSPICE and PSpice support documentation properties
hasdocprops(::Union{Hspice, Pspice}) = true

"""
    doc_only_params(simulator::AbstractSimulator) -> Set{Symbol}

Returns the set of parameter names that are documentation-only for this simulator.
These should be filtered out when generating netlists for simulators that don't support them.
"""
function doc_only_params(sim::AbstractSimulator)
    if hasdocprops(sim)
        return Set{Symbol}()  # No filtering needed
    else
        return Set{Symbol}([
            :iave,      # Average current (documentation)
            :vpk,       # Peak voltage (documentation)
            :mfg,       # Manufacturer code (documentation)
            :type,      # Device type description (documentation)
            :icrating,  # Current rating (documentation)
            :vceo,      # Collector-emitter voltage (documentation)
        ])
    end
end

# =============================================================================
# Magnitude Suffix Trait
# =============================================================================

"""
    magnitude_suffixes(simulator::AbstractSimulator) -> Dict{String, Float64}

Returns the magnitude suffixes supported by the simulator and their multipliers.

SPICE uses case-insensitive suffixes like:
- T (tera, 1e12), G (giga, 1e9), MEG (mega, 1e6), K (kilo, 1e3)
- M (milli, 1e-3), U (micro, 1e-6), N (nano, 1e-9), P (pico, 1e-12), F (femto, 1e-15)

Note: 'M' is ambiguous - could be mega or milli depending on context.
SPICE convention: uppercase M = milli, MEG = mega (case-insensitive).
"""
function magnitude_suffixes(::AbstractSpiceSimulator)
    Dict{String, Float64}(
        "T"   => 1e12,
        "G"   => 1e9,
        "MEG" => 1e6,
        "K"   => 1e3,
        "M"   => 1e-3,
        "U"   => 1e-6,
        "N"   => 1e-9,
        "P"   => 1e-12,
        "F"   => 1e-15,
        "A"   => 1e-18,
    )
end

# Spectre uses different conventions
function magnitude_suffixes(::AbstractSpectreSimulator)
    Dict{String, Float64}(
        "T"  => 1e12,
        "G"  => 1e9,
        "M"  => 1e6,   # Spectre: M = mega
        "K"  => 1e3,
        "m"  => 1e-3,  # Spectre: lowercase m = milli
        "u"  => 1e-6,
        "n"  => 1e-9,
        "p"  => 1e-12,
        "f"  => 1e-15,
        "a"  => 1e-18,
    )
end

# =============================================================================
# Device Support Traits (for future expansion)
# =============================================================================

"""
    supports_bsim_models(simulator::AbstractSimulator) -> Bool

Returns true if the simulator supports BSIM MOSFET models.
"""
supports_bsim_models(::AbstractSpiceSimulator) = true
supports_bsim_models(::AbstractSpectreSimulator) = true

"""
    supports_verilog_a(simulator::AbstractSimulator) -> Bool

Returns true if the simulator supports Verilog-A behavioral models.
"""
supports_verilog_a(::Ngspice) = false  # Ngspice has limited Verilog-A support
supports_verilog_a(::AbstractSimulator) = true

# =============================================================================
# Syntax Quirks (for future expansion)
# =============================================================================

"""
    requires_explicit_title(simulator::AbstractSimulator) -> Bool

Returns true if the simulator requires an explicit title line (first line of netlist).
"""
requires_explicit_title(::AbstractSpiceSimulator) = true  # SPICE requires title
requires_explicit_title(::AbstractSpectreSimulator) = false  # Spectre doesn't

"""
    case_sensitive(simulator::AbstractSimulator) -> Bool

Returns true if the simulator treats identifiers as case-sensitive.
"""
case_sensitive(::AbstractSpiceSimulator) = false  # SPICE is case-insensitive
case_sensitive(::AbstractSpectreSimulator) = true  # Spectre is case-sensitive

# =============================================================================
# Helper Functions
# =============================================================================

"""
    simulator_from_symbol(sym::Symbol) -> AbstractSimulator

Convert a dialect symbol to a simulator type instance.
This provides backward compatibility with the old symbol-based API.

Supported symbols:
- `:ngspice` → `Ngspice()`
- `:hspice` → `Hspice()`
- `:pspice` → `Pspice()`
- `:xyce` → `Xyce()`
- `:spectre` → `SpectreADE()`
"""
function simulator_from_symbol(sym::Symbol)
    if sym === :ngspice
        return Ngspice()
    elseif sym === :hspice
        return Hspice()
    elseif sym === :pspice
        return Pspice()
    elseif sym === :xyce
        return Xyce()
    elseif sym === :spectre
        return SpectreADE()
    else
        error("Unknown simulator dialect: $sym. Supported: :ngspice, :hspice, :pspice, :xyce, :spectre")
    end
end

"""
    symbol_from_simulator(sim::AbstractSimulator) -> Symbol

Convert a simulator type to a symbol.
This provides backward compatibility with the old symbol-based API.
"""
symbol_from_simulator(::Ngspice) = :ngspice
symbol_from_simulator(::Hspice) = :hspice
symbol_from_simulator(::Pspice) = :pspice
symbol_from_simulator(::Xyce) = :xyce
symbol_from_simulator(::SpectreADE) = :spectre
