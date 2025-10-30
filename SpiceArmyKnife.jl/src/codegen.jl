# SPICE/Spectre Code Generator
#
# This module provides functionality to generate SPICE/Spectre netlists from parsed ASTs.
# It mirrors the structure of src/spectre.jl but generates netlist code instead of Julia code.
#
# Key design:
# - Parametric CodeGenScope{Sim} where Sim <: AbstractSimulator for simulator-specific generation
# - Default implementation preserves original formatting via String(node)
# - Override specific node types for dialect conversion and parameter filtering
# - Use trait functions (hasdocprops, temperature_param_mapping, etc.) to handle simulator quirks
# - Non-recursive (single file) - caller handles include/lib traversal

# This file is included in SpiceArmyKnife module, so SNode, SC, SP are already in scope

# Import RedTree utilities
using SpectreNetlistParser.RedTree: fullcontents

# Import error checking
using SpectreNetlistParser: visit_errors

# Include simulator traits (defines types and trait functions)
include("simulator_traits.jl")

"""
    CodeGenScope{Sim}

Scope for generating SPICE/Spectre code from AST.

Type parameters:
- `Sim <: AbstractSimulator`: Simulator type (Ngspice, Hspice, Pspice, Xyce, SpectreADE, etc.)

Fields:
- `io`: Output IO buffer
- `indent`: Current indentation level (for readability)
- `options`: Dict for simulator-specific options
- `params`: Set of parameter names declared in current scope (for Verilog-A backtick resolution)
- `parent_scope`: Parent scope for hierarchical parameter lookup (nothing = global scope)
- `includepaths`: Vector of directories to search for include files (Verilog-A conversion)
- `processed_includes`: Cache mapping filename → local scope params (Verilog-A conversion)

The parametric type allows method specialization for different simulators:
```julia
(scope::CodeGenScope{Ngspice})(node::SNode{SP.Model})  # ngspice-specific Model
(scope::CodeGenScope{SpectreADE})(node::SNode{SC.Instance})  # Spectre instance
```

Simulator-specific behavior is controlled by trait functions like:
- `hasdocprops(Sim())` - whether to filter documentation parameters
- `temperature_param_mapping(Sim())` - parameter name conversions for dialect compatibility
"""
struct CodeGenScope{Sim <: AbstractSimulator}
    io::IO
    indent::Int
    options::Dict{Symbol, Any}
    params::Set{Symbol}
    parent_scope::Union{Nothing, CodeGenScope{Sim}}
    includepaths::Vector{String}
    processed_includes::Dict{String, Set{Symbol}}
end

# Constructor with optional indent and options (creates global scope with no parent)
function CodeGenScope{Sim}(io::IO, indent::Int=0, options::Dict{Symbol, Any}=Dict{Symbol, Any}(),
                           includepaths::Vector{String}=String[]) where {Sim <: AbstractSimulator}
    CodeGenScope{Sim}(io, indent, options, Set{Symbol}(), nothing, includepaths, Dict{String, Set{Symbol}}())
end

# Helper to create new scope with modified indent (preserves params, parent, includepaths, and cache)
with_indent(scope::CodeGenScope{Sim}, delta::Int) where {Sim <: AbstractSimulator} =
    CodeGenScope{Sim}(scope.io, scope.indent + delta, scope.options, scope.params, scope.parent_scope,
                      scope.includepaths, scope.processed_includes)

"""
    is_global_scope(scope::CodeGenScope) -> Bool

Check if this is the global (top-level) scope.
Global scope has no parent and is used for top-level .param → `define conversion.
"""
is_global_scope(scope::CodeGenScope) = scope.parent_scope === nothing

"""
    create_child_scope(scope::CodeGenScope{Sim}) -> CodeGenScope{Sim}

Create a child scope for a module/subcircuit.
Preserves IO, options, includepaths, and cache but creates new empty params set with parent link.
"""
function create_child_scope(scope::CodeGenScope{Sim}) where {Sim <: AbstractSimulator}
    CodeGenScope{Sim}(scope.io, scope.indent, scope.options, Set{Symbol}(), scope,
                      scope.includepaths, scope.processed_includes)
end

"""
    render_to_string(scope::CodeGenScope{Sim}, node) -> String

Render a node to a string by creating a temporary scope with an IOBuffer.
"""
function render_to_string(scope::CodeGenScope{Sim}, node) where {Sim <: AbstractSimulator}
    buf = IOBuffer()
    temp_scope = CodeGenScope{Sim}(buf, 0, scope.options, Set{Symbol}(), scope,
                                   scope.includepaths, scope.processed_includes)
    temp_scope(node)
    return String(take!(buf))
end

"""
    add_param(scope::CodeGenScope, name::Symbol)

Add a parameter name to the current scope's parameter set.
Used to track which identifiers are parameters for backtick resolution.
"""
function add_param(scope::CodeGenScope, name::Symbol)
    push!(scope.params, name)
end

"""
    needs_backtick(scope::CodeGenScope, identifier::Symbol) -> Bool

Determine if an identifier needs a backtick prefix for Verilog-A output.

At global scope (parent_scope === nothing):
- All identifiers need backtick prefix (referencing global `defines)

Inside modules:
- If found in current scope params → false (module parameter, use bare identifier)
- If not found → recurse to parent scope → true (global `define, needs backtick prefix)
"""
function needs_backtick(scope::CodeGenScope, identifier::Symbol)
    # At global scope, all identifiers need backtick prefix
    if scope.parent_scope === nothing
        return true
    end

    # Check current scope
    if identifier ∈ scope.params
        return false  # Local parameter, use bare identifier
    end

    # Not in current scope - check parent scopes recursively
    return needs_backtick(scope.parent_scope, identifier)
end

"""
    write_indent(scope::CodeGenScope)

Write indentation to output.
"""
function write_indent(scope::CodeGenScope)
    for _ in 1:scope.indent
        print(scope.io, "  ")
    end
end

"""
    write_terminal(scope::CodeGenScope, node)

Write a terminal node to output using `String(node)`.
This extracts the semantic content without leading/trailing trivia.
Use this for identifiers, keywords, operators, etc.
"""
write_terminal(scope::CodeGenScope, node::SNode) = print(scope.io, String(node))
write_terminal(scope::CodeGenScope, ::Nothing) = nothing

"""
    newline(scope::CodeGenScope)

Write a newline to output.
"""
newline(scope::CodeGenScope) = println(scope.io)

"""
    should_format_multiline(items) -> Bool

Determine if a list should be formatted with each item on its own line.
Returns true if the list has more than 5 items.
"""
should_format_multiline(items) = length(items) > 5

# =============================================================================
# Default Implementation - Preserve Original Formatting
# =============================================================================

"""
    (scope::CodeGenScope)(node::SNode)

Default fallback: preserve original source by calling fullcontents(node).
This is used for nodes we haven't specialized yet - it preserves the original
formatting including trivia (whitespace, comments).

For actual dialect conversion, you should specialize on specific node types
and recurse into their children rather than using this fallback.

Runtime validation ensures we don't accidentally output SPICE nodes with Spectre
simulators or vice versa (type safety without type system ambiguities).

WARNING: This fallback may prevent proper conversion and can cause issues with
whitespace accumulation in roundtrip tests. Consider adding an explicit handler
that recurses into the node's children.
"""
function (scope::CodeGenScope{Sim})(node::SNode{T}) where {Sim, T}
    # Runtime type safety check: prevent cross-language contamination
    if Sim <: AbstractSpiceSimulator && T <: SC.AbstractASTNode
        error("Cannot generate Spectre node type $T with SPICE simulator $Sim. This indicates a bug - SPICE simulators should not receive Spectre AST nodes.")
    elseif Sim <: AbstractSpectreSimulator && T <: SP.AbstractASTNode
        error("Cannot generate SPICE node type $T with Spectre simulator $Sim. This indicates a bug - Spectre simulators should not receive SPICE AST nodes.")
    elseif Sim <: AbstractVerilogASimulator
        error("Using fullcontents() fallback for Verilog-A is not supported. Node type $T requires an explicit Verilog-A handler.")
    end

    # Warn that we're using fullcontents fallback - indicates missing handler
    if get(scope.options, :warn_fallback, true)
        @warn "Using fullcontents() fallback for node type $T. Consider adding an explicit handler." maxlog=1 _id=hash(T)
    end

    # Default: preserve original formatting with fullcontents
    print(scope.io, fullcontents(node))
end

# Handle nothing nodes gracefully
(scope::CodeGenScope)(::Nothing) = nothing

# Handlers for numeric/string literals that can be emitted directly
(scope::CodeGenScope)(val::Real) = print(scope.io, val)
(scope::CodeGenScope)(val::AbstractString) = print(scope.io, val)

# =============================================================================
# Source and Block Nodes - Recurse into children
# =============================================================================

"""
Process block statements and netlists - just recurse into statements.
Handles all source and block nodes from both SPICE and Spectre.

These handlers are untyped on the scope because:
1. They only recurse into child statements - no simulator-specific logic
2. Type safety is enforced at the leaf nodes (devices, models, etc.) and in the fallback
3. More specific than the fallback (AbstractBlockASTNode vs AbstractASTNode)
"""
function (scope::CodeGenScope)(n::SNode{<:Union{SP.AbstractBlockASTNode, SC.AbstractBlockASTNode}})
    for stmt in n.stmts
        scope(stmt)
    end
end

# =============================================================================
# Terminal Nodes - Direct String Conversion
# =============================================================================

# Terminal handlers are language-specific (see cg_spice.jl, cg_spectre.jl, cg_veriloga.jl)

# =============================================================================
# Expression Nodes - May need conversion between dialects
# =============================================================================

# Binary expressions: +, -, *, /, **, etc.
function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SC.BinaryExpression, SP.BinaryExpression}}) where {Sim}
    op_str = String(n.op)
    emission_type, replacement = operator_replacement(Sim(), op_str)

    if emission_type == :function
        # Emit as function call: pow(x, y)
        print(scope.io, replacement, "(")
        scope(n.lhs)
        print(scope.io, ", ")
        scope(n.rhs)
        print(scope.io, ")")
    else
        # Emit as infix operator: x ** y
        scope(n.lhs)
        print(scope.io, " ", replacement, " ")
        scope(n.rhs)
    end
end

# Unary expressions: -, +, !, ~
function (scope::CodeGenScope)(n::SNode{<:Union{SC.UnaryOp, SP.UnaryOp}})
    print(scope.io, String(n.op))
    scope(n.operand)
end

# Ternary expressions: condition ? true_val : false_val
function (scope::CodeGenScope)(n::SNode{<:Union{SC.TernaryExpr, SP.TernaryExpr}})
    scope(n.condition)
    print(scope.io, " ? ")
    scope(n.ifcase)
    print(scope.io, " : ")
    scope(n.elsecase)
end

# Parenthesized expressions
function (scope::CodeGenScope)(n::SNode{<:Union{SC.Parens, SP.Parens}})
    print(scope.io, "(")
    scope(n.inner)
    print(scope.io, ")")
end

# Function calls
function (scope::CodeGenScope)(n::SNode{<:Union{SC.FunctionCall, SP.FunctionCall}})
    print(scope.io, String(n.id), "(")
    first_arg = true
    for arg in n.args
        if !first_arg
            print(scope.io, ", ")
        end
        scope(arg.item)
        first_arg = false
    end
    print(scope.io, ")")
end

# =============================================================================
# Numeric Literals - Handle magnitude suffixes
# =============================================================================

# Numeric literals are handled by the default fallback (String(node))
# Dialect-specific magnitude conversion can be added as specializations
# For example:
# function (scope::CodeGenScope{:spectre, :spectre})(n::SNode{SP.NumberLiteral})
#     # Convert SPICE magnitude suffixes to Spectre format
# end


# =============================================================================
# Parameters
# =============================================================================

# Generic parameter handler (works for all languages)
function (scope::CodeGenScope)(n::SNode{<:Union{SC.Parameter, SP.Parameter}})
    write_terminal(scope, n.name)
    if n.val !== nothing
        print(scope.io, "=")
        scope(n.val)
    end
end

# =============================================================================
# Simulator-Specific Specializations Using Traits
# =============================================================================

"""
    write_leading_trivia(scope::CodeGenScope, n::SNode)

Write the leading trivia (whitespace and comments) for a node.
"""
function write_leading_trivia(scope::CodeGenScope, n::SNode)
    # Leading trivia is from n.startof to n.startof + n.expr.off
    if n.expr.off > 0
        SpectreNetlistParser.RedTree.print_contents(scope.io, n.ps, n.startof, n.startof + n.expr.off - 1)
    end
end

"""
    should_filter_param(scope::CodeGenScope{Sim}, param_name::Symbol) where {Sim}

Check if a parameter should be filtered out for the target simulator.
Uses the hasdocprops trait to determine if documentation parameters should be kept.
"""
function should_filter_param(scope::CodeGenScope{Sim}, param_name::Symbol) where {Sim}
    # If simulator supports doc props, don't filter anything
    if hasdocprops(Sim())
        return false
    end

    # Otherwise, check if this param is a doc-only param
    return param_name ∈ doc_only_params(Sim())
end

"""
    convert_param_name(scope::CodeGenScope{Sim}, param_name::Symbol) where {Sim}

Convert a parameter name if needed for the target simulator.
Uses the temperature_param_mapping trait to handle PSPICE → Ngspice conversions.

Returns the converted parameter name, or the original if no conversion is needed.
"""
function convert_param_name(scope::CodeGenScope{Sim}, param_name::Symbol) where {Sim}
    # Get temperature parameter mapping for this simulator
    temp_mapping = temperature_param_mapping(Sim())

    # Check if this parameter needs conversion
    param_lower = Symbol(lowercase(string(param_name)))
    if haskey(temp_mapping, param_lower)
        return temp_mapping[param_lower]
    end

    # No conversion needed
    return param_name
end

# =============================================================================
# Public API
# =============================================================================

"""
    generate_code(ast::SNode, simulator::AbstractSimulator; options::Dict=Dict(), includepaths::Vector{String}=String[]) -> String

Generate SPICE/Spectre code from parsed AST for a specific simulator.

Arguments:
- `ast`: Parsed netlist AST (from SpectreNetlistParser)
- `simulator`: Target simulator instance (Ngspice(), Hspice(), Pspice(), Xyce(), SpectreADE())
- `options`: Optional simulator-specific options
- `includepaths`: Directories to search for include files (required for Verilog-A conversion with includes)

Returns:
- Generated code as String

Note: If the AST contains parse errors, a warning will be printed. Error lines will
be preserved as-is without reformatting.

Example:
```julia
# Parse SPICE file
ast = SpectreNetlistParser.parsefile("input.sp")

# Generate for different simulators
ngspice_code = generate_code(ast, Ngspice())
hspice_code = generate_code(ast, Hspice())
spectre_code = generate_code(ast, SpectreADE())

# Verilog-A conversion with include processing
va_code = generate_code(ast, OpenVAF(), includepaths=["/path/to/models", "."])
```
"""
function generate_code(ast::SNode, simulator::AbstractSimulator; options::Dict=Dict{Symbol, Any}(), includepaths::Vector{String}=String[])
    # Check for parse errors and warn user
    if ast.ps.errored
        @warn "AST contains parse errors. Error lines will not be reformatted."
        visit_errors(ast; io=stderr)
    end

    io = IOBuffer()
    scope = CodeGenScope{typeof(simulator)}(io, 0, options, includepaths)
    scope(ast)
    return String(take!(io))
end

"""
    generate_code(ast::SNode, io::IO, simulator::AbstractSimulator; options::Dict=Dict(), includepaths::Vector{String}=String[])

Generate SPICE/Spectre code to an IO stream for a specific simulator.

Arguments:
- `ast`: Parsed netlist AST
- `io`: Output IO stream
- `simulator`: Target simulator instance
- `options`: Optional simulator-specific options
- `includepaths`: Directories to search for include files (required for Verilog-A conversion with includes)

Note: If the AST contains parse errors, a warning will be printed. Error lines will
be preserved as-is without reformatting.

Example:
```julia
open("output.sp", "w") do io
    generate_code(ast, io, Ngspice())
end

# Verilog-A with include processing
open("output.va", "w") do io
    generate_code(ast, io, OpenVAF(), includepaths=["/path/to/models", "."])
end
```
"""
function generate_code(ast::SNode, io::IO, simulator::AbstractSimulator; options::Dict=Dict{Symbol, Any}(), includepaths::Vector{String}=String[])
    # Check for parse errors and warn user
    if ast.ps.errored
        @warn "AST contains parse errors. Error lines will not be reformatted."
        visit_errors(ast; io=stderr)
    end

    scope = CodeGenScope{typeof(simulator)}(io, 0, options, includepaths)
    scope(ast)
end


export CodeGenScope, generate_code, write_indent, write_terminal, newline, with_indent

# Include language-specific code generators
include("cg_spice.jl")
include("cg_spectre.jl")
include("cg_veriloga.jl")

# Export simulator types and traits from this module
export AbstractSimulator, AbstractSpiceSimulator, AbstractSpectreSimulator, AbstractVerilogASimulator
export Ngspice, Hspice, Pspice, Xyce, SpectreADE, OpenVAF, Gnucap
export language, hasdocprops, doc_only_params, temperature_param_mapping, operator_replacement
export symbol_from_simulator, simulator_from_symbol
