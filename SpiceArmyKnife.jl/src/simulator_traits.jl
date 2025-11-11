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

"""
    AbstractVerilogASimulator <: AbstractSimulator

Base type for Verilog-A simulators.
These simulators compile and execute Verilog-A behavioral models.
"""
abstract type AbstractVerilogASimulator <: AbstractSimulator end

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

"""
    VACASK <: AbstractSpectreSimulator

VACASK - open source Spectre-compatible simulator.
"""
struct VACASK <: AbstractSpectreSimulator end

# Verilog-A simulators
"""
    OpenVAF <: AbstractVerilogASimulator

OpenVAF - open source Verilog-A compiler and simulator.
Compiles Verilog-A models to optimized machine code.
"""
struct OpenVAF <: AbstractVerilogASimulator end

"""
    Gnucap <: AbstractVerilogASimulator

GNU Circuit Analysis Package - open source general purpose circuit simulator.
Supports Verilog-A behavioral models through plugin system.
"""
struct Gnucap <: AbstractVerilogASimulator end

# =============================================================================
# Language Trait
# =============================================================================

"""
    language(::AbstractSimulator) -> Symbol

Returns the netlist language used by the simulator (`:spice`, `:spectre`, or `:verilog_a`).
"""
language(::AbstractSpiceSimulator) = :spice
language(::AbstractSpectreSimulator) = :spectre
language(::AbstractVerilogASimulator) = :verilog_a

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
# PSPICE Temperature Parameter Conversion Trait
# =============================================================================

"""
    temperature_param_mapping(simulator::AbstractSimulator) -> Dict{Symbol, Symbol}

Returns a mapping of PSPICE-specific temperature parameter names to standard SPICE names.

PSPICE uses proprietary temperature parameter names that need conversion for other simulators:
- `T_ABS` → `temp` (absolute temperature)
- `T_REL_GLOBAL` → `dtemp` (relative temperature offset)
- `T_MEASURED` → `TNOM` (nominal/measurement temperature)

This trait enables automatic parameter name conversion when generating netlists.

Default behavior (for PSPICE/HSPICE): Returns empty dict (no conversion)
Ngspice/Xyce: Returns conversion mapping

Reference: ngspice inpcompat.c:1061-1075 (PSPICE compatibility mode)
"""
function temperature_param_mapping(::AbstractSimulator)
    # Default: no conversion (preserve PSPICE names)
    return Dict{Symbol, Symbol}()
end

# Ngspice requires PSPICE temperature parameters to be converted
function temperature_param_mapping(::Ngspice)
    Dict{Symbol, Symbol}(
        :t_abs => :temp,           # Absolute temperature
        :t_rel_global => :dtemp,   # Relative temperature (delta)
        :t_measured => :tnom,      # Nominal/measurement temperature
    )
end

# Xyce also requires conversion (similar to Ngspice)
function temperature_param_mapping(::Xyce)
    Dict{Symbol, Symbol}(
        :t_abs => :temp,
        :t_rel_global => :dtemp,
        :t_measured => :tnom,
    )
end

# VACASK requires conversion from ngspice parameter names
# Note: VACASK Verilog-A models use tnom as the primary parameter.
# Some models (diode, BJT) provide tref as an aliasparam for compatibility,
# but not all models (e.g., resistor) have this alias. Always use tnom.
function temperature_param_mapping(::VACASK)
    Dict{Symbol, Symbol}(
        :tref => :tnom,  # ngspice compatibility alias → primary parameter
    )
end

# =============================================================================
# Operator Replacement Trait
# =============================================================================

"""
    operator_replacement(simulator::AbstractSimulator, op::String) -> Tuple{Symbol, String}

Returns how to emit an operator for a specific simulator.

Returns a tuple of (emission_type, replacement):
- `(:operator, "**")` - emit as infix operator (default, no conversion)
- `(:operator, "^")` - replace with different infix operator
- `(:function, "pow")` - replace with function call

Default: `(:operator, op)` - return input unchanged

This trait allows simulators to specify operator conversions. For example, gnucap does not
support the `**` power operator and requires `pow(x, y)` function calls instead.

Example:
```julia
operator_replacement(Gnucap(), "**")  # => (:function, "pow")
operator_replacement(Ngspice(), "**") # => (:operator, "**")  # no conversion
```
"""
operator_replacement(::AbstractSimulator, op::String) = (:operator, op)

# Gnucap does NOT support ** operator, requires pow() function
operator_replacement(::Gnucap, op::String) = op == "**" ? (:function, "pow") : (:operator, op)

# =============================================================================
# Model Binning Support Trait
# =============================================================================

"""
    binningsupport(simulator::AbstractSimulator) -> Bool

Returns true if the simulator has built-in model binning support.

Model binning is a technique where multiple model cards with different parameter ranges
are combined into a single model that selects the appropriate parameter set based on
device dimensions (L and W). Models are identified by LMIN, LMAX, WMIN, WMAX parameters.

Most simulators (NGSPICE, Xyce, Spectre, etc.) have runtime binning selection built-in.
VACASK does not support runtime binning, so binned models must be converted to explicit
if-expressions at the netlist level.

Default: true (most simulators have built-in binning support)
VACASK: false (requires explicit if-expression generation for binned models)
"""
binningsupport(::AbstractSimulator) = true

# VACASK does NOT support binning - requires explicit if-expressions
binningsupport(::VACASK) = false

# =============================================================================
# Helper Functions
# =============================================================================

"""
    symbol_from_simulator(sim::AbstractSimulator) -> Symbol

Convert a simulator type instance to a symbol.
Used for interfacing with parser code that expects symbol-based dialect specification.
"""
symbol_from_simulator(::Ngspice) = :ngspice
symbol_from_simulator(::Hspice) = :hspice
symbol_from_simulator(::Pspice) = :pspice
symbol_from_simulator(::Xyce) = :xyce
symbol_from_simulator(::SpectreADE) = :spectre
symbol_from_simulator(::OpenVAF) = :openvaf
symbol_from_simulator(::Gnucap) = :gnucap
symbol_from_simulator(::VACASK) = :vacask

"""
    simulator_from_symbol(dialect::Symbol) -> AbstractSimulator

Convert a dialect symbol to a simulator type instance.

Supported dialects:
- `:ngspice` → Ngspice()
- `:hspice` → Hspice()
- `:pspice` → Pspice()
- `:xyce` → Xyce()
- `:spectre` → SpectreADE()
- `:openvaf` → OpenVAF()
- `:gnucap` → Gnucap()

Throws an error if the dialect is not recognized.
"""
function simulator_from_symbol(dialect::Symbol)
    dialect_map = Dict(
        :ngspice => Ngspice(),
        :hspice => Hspice(),
        :pspice => Pspice(),
        :xyce => Xyce(),
        :spectre => SpectreADE(),
        :openvaf => OpenVAF(),
        :gnucap => Gnucap(),
        :vacask => VACASK(),
    )

    if !haskey(dialect_map, dialect)
        error("Unknown dialect: $dialect. Supported dialects: $(join(keys(dialect_map), ", "))")
    end

    return dialect_map[dialect]
end
