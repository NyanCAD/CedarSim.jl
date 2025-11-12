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
# Parameter Mapping and Filtering Trait
# =============================================================================

"""
    parameter_mapping(simulator::AbstractSimulator) -> Dict{Symbol, Union{Symbol, Nothing}}

Returns a mapping of parameter names for dialect conversion and filtering.

Maps lowercase parameter names to their target names or nothing for filtering:
- `param => :new_param` - rename parameter
- `param => nothing` - filter out (remove) parameter

This unified trait handles:
- Documentation parameter filtering (e.g., iave, vpk, mfg for Ngspice)
- Parameter name conversion (e.g., PSPICE T_MEASURED → tnom for Ngspice)
- Dialect-specific parameter aliases (e.g., tref → tnom for VACASK)

Default: empty dict (no mapping or filtering)

Examples:
```julia
# Ngspice filters doc params and converts PSPICE temperature params
parameter_mapping(Ngspice()) # => Dict(
    :iave => nothing,        # Filter doc param
    :t_measured => :tnom,    # Convert PSPICE param
    ...
)

# HSPICE/PSpice preserve all parameters
parameter_mapping(Hspice()) # => Dict() (empty, no changes)

# VACASK converts ngspice aliases
parameter_mapping(VACASK()) # => Dict(:tref => :tnom)
```

Reference:
- ngspice inpcompat.c:1061-1075 (PSPICE compatibility)
- VACASK Verilog-A models (tnom as primary parameter)
"""
function parameter_mapping(::AbstractSimulator)
    # Default: no mapping or filtering
    return Dict{Symbol, Union{Symbol, Nothing}}()
end

# Ngspice filters documentation parameters and converts PSPICE temperature parameters
function parameter_mapping(::Ngspice)
    Dict{Symbol, Union{Symbol, Nothing}}(
        # Documentation parameters - filter out (Ngspice doesn't support)
        :iave => nothing,        # Average current (documentation)
        :vpk => nothing,         # Peak voltage (documentation)
        :mfg => nothing,         # Manufacturer code (documentation)
        :type => nothing,        # Device type description (documentation)
        :icrating => nothing,    # Current rating (documentation)
        :vceo => nothing,        # Collector-emitter voltage (documentation)

        # PSPICE temperature parameter conversions
        :t_abs => :temp,         # Absolute temperature
        :t_rel_global => :dtemp, # Relative temperature (delta)
        :t_measured => :tnom,    # Nominal/measurement temperature
    )
end

# Xyce has similar requirements to Ngspice
function parameter_mapping(::Xyce)
    Dict{Symbol, Union{Symbol, Nothing}}(
        # Documentation parameters - filter out
        :iave => nothing,
        :vpk => nothing,
        :mfg => nothing,
        :type => nothing,
        :icrating => nothing,
        :vceo => nothing,

        # PSPICE temperature parameter conversions
        :t_abs => :temp,
        :t_rel_global => :dtemp,
        :t_measured => :tnom,
    )
end

# HSPICE and PSpice support documentation parameters, no filtering needed
# Default empty dict applies (no mapping or filtering)

# VACASK requires conversion from ngspice parameter names and filtering of binning/device mapping params
# Note: VACASK Verilog-A models use tnom as the primary parameter.
# Some models (diode, BJT) provide tref as an aliasparam for compatibility,
# but not all models (e.g., resistor) have this alias. Always use tnom.
function parameter_mapping(::VACASK)
    Dict{Symbol, Union{Symbol, Nothing}}(
        :tref => :tnom,  # ngspice compatibility alias → primary parameter

        # Binning parameters - VACASK does not support runtime binning
        :lmin => nothing,
        :lmax => nothing,
        :wmin => nothing,
        :wmax => nothing,

        # Device mapping parameters - handled by model selection
        :level => nothing,
        :version => nothing,
    )
end

# OpenVAF and Gnucap also need binning/device mapping parameter filtering
function parameter_mapping(::Union{OpenVAF, Gnucap})
    Dict{Symbol, Union{Symbol, Nothing}}(
        # Binning parameters - not supported in Verilog-A output
        :lmin => nothing,
        :lmax => nothing,
        :wmin => nothing,
        :wmax => nothing,

        # Device mapping parameters - handled by model selection
        :level => nothing,
        :version => nothing,
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
