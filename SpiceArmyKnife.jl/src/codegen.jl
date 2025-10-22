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

# Import types from parent module - reuse parent's imports
import ..SNode, ..SC, ..SP

# Import RedTree utilities
using ..SpectreNetlistParser.RedTree: fullcontents

# Import error checking
using ..SpectreNetlistParser: visit_errors

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

# Terminals use String(node) to get semantic content without trivia
# Terminal handlers - only for same-language conversions (SPICE→SPICE, Spectre→Spectre)
# For cross-language conversions (→Verilog-A), we need explicit handlers for each terminal type
function (scope::CodeGenScope{Sim})(n::SNode{<:SP.Terminal}) where {Sim <: AbstractSpiceSimulator}
    print(scope.io, String(n))
end

function (scope::CodeGenScope{Sim})(n::SNode{<:SC.Terminal}) where {Sim <: AbstractSpectreSimulator}
    print(scope.io, String(n))
end

# Verilog-A terminal handlers - explicit support for common terminals
function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.Operator, SC.Operator}}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, String(n))
end

function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.StringLiteral, SC.StringLiteral}}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, String(n))
end

# =============================================================================
# Expression Nodes - May need conversion between dialects
# =============================================================================

# Binary expressions: +, -, *, /, **, etc.
function (scope::CodeGenScope)(n::SNode{<:Union{SC.BinaryExpression, SP.BinaryExpression}})
    scope(n.lhs)
    print(scope.io, " ", String(n.op), " ")
    scope(n.rhs)
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
# Arrays
# =============================================================================

function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.SpectreArray})
    print(scope.io, "[")
    first_item = true
    for item in n.items
        if !first_item
            print(scope.io, " ")
        end
        scope(item)
        first_item = false
    end
    print(scope.io, "]")
end

# =============================================================================
# Node references (prevents fullcontents fallback)
# =============================================================================

# SPICE NodeName: base node name (contains Identifier or NumberLiteral)
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.NodeName})
    scope(n.name)  # name is Terminal (Identifier or NumberLiteral)
end

# SPICE HierarchialNode: node names with optional subnodes (e.g., "vdd", "n1", "foo.bar")
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.HierarchialNode})
    scope(n.base)
    for subnode in n.subnodes
        scope(subnode)
    end
end

# Spectre SNode: node reference with optional subcircuit qualifiers
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.SNode})
    for subckt in n.subckts
        scope(subckt)
    end
    scope(n.node)  # node is Terminal (Identifier or NumberLiteral)
end

# =============================================================================
# Title and Braces
# =============================================================================

# SPICE Title: first line of SPICE file (optional .title keyword + comment line)
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Title})
    if n.dot !== nothing
        scope(n.dot)
    end
    if n.kw !== nothing
        scope(n.kw)
        print(scope.io, " ")
    end
    scope(n.line)
    scope(n.nl)
end

# SPICE Brace: parameter value in braces {expr}
# Contains expressions that may need modification for dialect conversion
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Brace})
    print(scope.io, "{")
    scope(n.inner)
    print(scope.io, "}")
end

# =============================================================================
# Parameters
# =============================================================================

function (scope::CodeGenScope)(n::SNode{<:Union{SC.Parameter, SP.Parameter}})
    write_terminal(scope, n.name)
    if n.val !== nothing
        print(scope.io, "=")
        scope(n.val)
    end
end

# SPICE .param statement: .param name1=val1 name2=val2 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.ParamStatement})
    scope(n.dot)
    scope(n.kw)
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    scope(n.nl)
end

# =============================================================================
# Models
# =============================================================================

# Note: SPICE .model has a trait-based handler below at line ~648 that handles
# parameter filtering and conversion. No generic handler needed here.

# Spectre: model name master_name param1=val1 param2=val2
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.Model})
    print(scope.io, "model ")
    scope(n.name)
    print(scope.io, " ")
    scope(n.master_name)
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# =============================================================================
# Subcircuits
# =============================================================================

# SPICE: .subckt name node1 node2 ... param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Subckt})
    print(scope.io, ".subckt ")
    scope(n.name)
    for node in n.subckt_nodes
        print(scope.io, " ")
        scope(node)
    end
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)

    # Body statements
    for stmt in n.stmts
        scope(stmt)
    end

    # End
    print(scope.io, ".ends")
    if n.name_end !== nothing
        print(scope.io, " ")
        scope(n.name_end)
    end
    println(scope.io)
end

# Spectre: subckt name (node1 node2 ...)
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.Subckt})
    if n.inline !== nothing
        print(scope.io, "inline ")
    end
    print(scope.io, "subckt ")
    scope(n.name)

    # Nodes in parentheses
    if n.subckt_nodes !== nothing
        print(scope.io, " (")
        first = true
        for node in n.subckt_nodes.nodes
            if !first
                print(scope.io, " ")
            end
            scope(node)
            first = false
        end
        print(scope.io, ")")
    end
    println(scope.io)

    # Body statements
    for stmt in n.stmts
        scope(stmt)
    end

    # End
    print(scope.io, "ends")
    if n.end_name !== nothing
        print(scope.io, " ")
        scope(n.end_name)
    end
    println(scope.io)
end

# =============================================================================
# SPICE Device Instances
# =============================================================================

# SPICE MOSFET: Mname drain gate source bulk model param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.MOSFET})
    scope(n.name)
    print(scope.io, " ")
    scope(n.d)
    print(scope.io, " ")
    scope(n.g)
    print(scope.io, " ")
    scope(n.s)
    print(scope.io, " ")
    scope(n.b)
    print(scope.io, " ")
    scope(n.model)
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Resistor: Rname pos neg value/model param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Resistor})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    if n.val !== nothing
        print(scope.io, " ")
        scope(n.val)
    end
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Capacitor: Cname pos neg value/model param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Capacitor})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    if n.val !== nothing
        print(scope.io, " ")
        scope(n.val)
    end
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Inductor: Lname pos neg value/model param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Inductor})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    if n.val !== nothing
        print(scope.io, " ")
        scope(n.val)
    end
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Diode: Dname pos neg model param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Diode})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    print(scope.io, " ")
    scope(n.model)
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Voltage source: Vname pos neg type value param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Voltage})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    if n.val !== nothing
        print(scope.io, " ")
        scope(n.val)
    end
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Current source: Iname pos neg type value param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.Current})
    scope(n.name)
    print(scope.io, " ")
    scope(n.pos)
    print(scope.io, " ")
    scope(n.neg)
    if n.val !== nothing
        print(scope.io, " ")
        scope(n.val)
    end
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Subcircuit call: Xname node1 node2 ... subckt_name param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpiceSimulator})(n::SNode{SP.SubcktCall})
    scope(n.name)
    for node in n.nodes
        print(scope.io, " ")
        scope(node)
    end
    print(scope.io, " ")
    scope(n.model)
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# =============================================================================
# Spectre Instance
# =============================================================================

# Spectre Instance: name (node1 node2 ...) master param1=val1 ...
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.Instance})
    scope(n.name)
    print(scope.io, " (")

    # Nodes
    first = true
    for node in n.nodelist.nodes
        if !first
            print(scope.io, " ")
        end
        scope(node)
        first = false
    end

    print(scope.io, ") ")
    scope(n.master)

    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
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

# SPICE Model handler for simulators that require parameter conversion or filtering
# This uses the trait system to:
# 1. Filter documentation parameters based on simulator capabilities
# 2. Convert PSPICE temperature parameters to standard SPICE names
function (scope::CodeGenScope{Sim})(n::SNode{SP.Model}) where {Sim <: AbstractSpiceSimulator}
    # Preserve leading comments
    write_leading_trivia(scope, n)

    print(scope.io, ".model ")
    scope(n.name)
    print(scope.io, " ")
    scope(n.typ)
    for param in n.parameters
        param_name_str = String(param.name)
        param_name_sym = Symbol(lowercase(param_name_str))

        # Use trait-based filtering for documentation parameters
        if should_filter_param(scope, param_name_sym)
            continue  # Skip this parameter
        end

        # Check if parameter name needs conversion (e.g., PSPICE → Ngspice)
        converted_name = convert_param_name(scope, param_name_sym)

        print(scope.io, " ")
        if converted_name != param_name_sym
            # Parameter name was converted - output new name
            print(scope.io, uppercase(string(converted_name)))
        else
            # No conversion - output original name with original casing
            scope(param.name)
        end

        # Always output the parameter value
        if param.val !== nothing
            print(scope.io, "=")
            scope(param.val)
        end
    end
    println(scope.io)
end

# Example: SPICE to Spectre magnitude suffix conversion
# SPICE uses case-insensitive "meg" for 1e6, Spectre uses "M"
# This would need more sophisticated parsing of the literal to work properly
# For now, these are placeholders showing how to specialize

# SPICE float literals when generating Spectre output might need magnitude conversion
# function (scope::CodeGenScope{:spectre, :spectre})(n::SNode{SP.FloatLiteral})
#     # Would need to parse the float, extract magnitude, convert, and regenerate
#     # For now, use default String(node) behavior
#     write_node(scope, n)
# end

# Example: Convert between SPICE and Spectre function names
# function (scope::CodeGenScope{:spectre, :spectre})(n::SNode{SP.FunctionCall})
#     # Could map SPICE functions to Spectre equivalents
#     # For now, preserve original
#     write_node(scope, n)
# end

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

# =============================================================================
# Verilog-A / OpenVAF Code Generation
# =============================================================================

"""
    convert_magnitude_to_exponential(s::AbstractString) -> String

Convert SPICE magnitude suffixes to exponential notation for Verilog-A.

Examples:
- "1k" → "1e3"
- "2.682n" → "2.682e-9"
- "100u" → "100e-6"
- "1.5meg" → "1.5e6"

Supported suffixes:
- T/t: 1e12 (tera)
- G/g: 1e9 (giga)
- meg/MEG: 1e6 (mega - special case, case insensitive)
- k/K: 1e3 (kilo)
- m: 1e-3 (milli)
- u/µ/U: 1e-6 (micro)
- n/N: 1e-9 (nano)
- p/P: 1e-12 (pico)
- f/F: 1e-15 (femto)
"""
function convert_magnitude_to_exponential(s::AbstractString)
    s_trimmed = strip(s)

    # Try to match number + optional magnitude suffix
    # Pattern: optional sign, digits, optional decimal point and more digits, optional exponent, optional magnitude
    m = match(r"^([+-]?(?:\d+\.?\d*|\d*\.\d+)(?:[eE][+-]?\d+)?)(meg|MEG|[TGKkmuµnpfUNPF])?$"i, s_trimmed)

    if m === nothing
        # No magnitude suffix, return as-is
        return s_trimmed
    end

    num_part = m.captures[1]
    suffix = m.captures[2]

    if suffix === nothing
        return num_part
    end

    # Map suffix to exponent
    exponent = if occursin(r"^meg$"i, suffix)
        "e6"
    elseif suffix in ["T", "t"]
        "e12"
    elseif suffix in ["G", "g"]
        "e9"
    elseif suffix in ["k", "K"]
        "e3"
    elseif suffix == "m"
        "e-3"
    elseif suffix in ["u", "µ", "U"]
        "e-6"
    elseif suffix in ["n", "N"]
        "e-9"
    elseif suffix in ["p", "P"]
        "e-12"
    elseif suffix in ["f", "F"]
        "e-15"
    else
        # Unknown suffix, return original
        return s_trimmed
    end

    return num_part * exponent
end

"""
    spice_device_type_to_va_module(device_type::AbstractString) -> String

Map SPICE device type codes to Verilog-A module names.

Supported mappings:
- "D" → "diode"
- "R" → "resistor"
- "C" → "capacitor"
- "L" → "inductor"
"""
function spice_device_type_to_va_module(device_type::AbstractString)
    device_upper = uppercase(strip(device_type))

    mapping = Dict(
        "D" => "diode",
        "R" => "resistor",
        "C" => "capacitor",
        "L" => "inductor",
    )

    return get(mapping, device_upper, device_upper)
end

# =============================================================================
# Verilog-A Handlers - Convert SPICE/Spectre to Verilog-A
# =============================================================================

# Handler for NumberLiteral in Verilog-A context - convert magnitude suffixes
function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.NumberLiteral, SC.NumberLiteral}}) where {Sim <: AbstractVerilogASimulator}
    val_str = String(n)
    converted_val = convert_magnitude_to_exponential(val_str)
    print(scope.io, converted_val)
end

# Verilog-A handler for SPICE Title - skip it (Verilog-A doesn't use title lines)
function (scope::CodeGenScope{Sim})(n::SNode{SP.Title}) where {Sim <: AbstractVerilogASimulator}
    # No-op: Verilog-A doesn't have title lines, skip them
    nothing
end

# Verilog-A handler for SPICE .lib blocks
# Converts to `ifdef ... `endif conditional compilation
function (scope::CodeGenScope{Sim})(n::SNode{SP.LibStatement}) where {Sim <: AbstractVerilogASimulator}
    lib_name = String(n.name)

    # Emit `ifdef directive
    println(scope.io, "`ifdef ", lib_name)

    # Process body statements
    for stmt in n.stmts
        scope(stmt)
    end

    # Emit `endif
    println(scope.io, "`endif")
    println(scope.io)  # Extra blank line after lib block
end

# Verilog-A handler for SPICE .include statements
# Recursively processes included files with inherited scope
# - If output is a file: writes to separate .va file in same directory, emits `include directive
# - If output is memory (IOBuffer): inlines the content directly, no `include directive
function (scope::CodeGenScope{Sim})(n::SNode{SP.IncludeStatement}) where {Sim <: AbstractVerilogASimulator}
    # Strip outer quotes from path (preserves escape sequences)
    path_str = strip(String(n.path), ['"', '\''])

    # Compute output path with .va extension (preserve relative directory structure)
    output_relpath = splitext(path_str)[1] * ".va"

    # Resolve the full path to the include file
    fullpath = resolve_includepath(path_str, scope.includepaths)

    # Check if already processed
    if haskey(scope.processed_includes, fullpath)
        # Validate scope matches
        cached_params = scope.processed_includes[fullpath]
        if cached_params != scope.params
            @warn "Include file $fullpath included from contexts with different scopes" cached_scope=cached_params current_scope=scope.params
        end
    else
        # Not yet processed - parse and convert recursively
        try
            spice_dialect = get(scope.options, :spice_dialect, :ngspice)
            inc_ast = SP.parsefile(fullpath; implicit_title=false, spice_dialect)

            if inc_ast.ps.errored
                @warn "Parse errors in included file: $fullpath"
                visit_errors(inc_ast; io=stderr)
            end

            # Determine if we're writing to a file or memory
            if scope.io isa IOStream
                # Writing to file - create separate .va file, mirroring directory structure
                output_dir = get(scope.options, :output_dir, ".")
                output_path = joinpath(output_dir, output_relpath)

                # Create directory structure if needed (equivalent to mkdir -p)
                mkpath(dirname(output_path))

                # Create new scope for included file with file IO
                # Prepend directory of included file so nested includes resolve relative to it
                inc_includepaths = [dirname(fullpath), scope.includepaths...]
                open(output_path, "w") do inc_io
                    inc_scope = CodeGenScope{Sim}(inc_io, 0, scope.options, scope.params, scope.parent_scope,
                                                  inc_includepaths, scope.processed_includes)
                    inc_scope(inc_ast)
                end
            else
                # Writing to memory (IOBuffer) - inline the content directly
                scope(inc_ast)
            end

            # Cache the scope parameters for this file
            scope.processed_includes[fullpath] = copy(scope.params)
        catch e
            @warn "Failed to process include file: $fullpath" exception=(e, catch_backtrace())
            # Continue with main conversion despite include failure
        end
    end

    # Emit `include directive only if writing to file (mirrors file structure)
    if scope.io isa IOStream
        println(scope.io, "`include \"", output_relpath, "\"")
    end
    # If IOBuffer: content already inlined, no directive needed
end

# Verilog-A handler for SPICE .param statements
# Top-level: converts to `define macros (global scope)
# Module-level: converts to parameter declarations (scoped to module)
function (scope::CodeGenScope{Sim})(n::SNode{SP.ParamStatement}) where {Sim <: AbstractVerilogASimulator}
    for param in n.params
        param_name_str = String(param.name)
        param_name_sym = Symbol(lowercase(param_name_str))

        # Track parameter in current scope
        add_param(scope, param_name_sym)

        if is_global_scope(scope)
            # Top-level: emit `define macro
            print(scope.io, "`define ", param_name_str, " ")
            if param.val !== nothing
                scope(param.val)
            else
                # Parameter without value - default to 1
                print(scope.io, "1")
            end
            println(scope.io)
        else
            # Module-level: emit parameter declaration
            write_indent(scope)
            print(scope.io, "parameter real ", param_name_str, " = ")
            if param.val !== nothing
                scope(param.val)
            else
                # Parameter without value - default to 0
                print(scope.io, "0")
            end
            println(scope.io, ";")
        end
    end
end

# Verilog-A handler for SPICE Identifier - add backtick for global `define references
function (scope::CodeGenScope{Sim})(n::SNode{SP.Identifier}) where {Sim <: AbstractVerilogASimulator}
    identifier_str = String(n)
    identifier_sym = Symbol(lowercase(identifier_str))

    if needs_backtick(scope, identifier_sym)
        # Global parameter - needs backtick prefix
        print(scope.io, "`", identifier_str)
    else
        # Module parameter - use bare identifier
        print(scope.io, identifier_str)
    end
end

# Verilog-A handler for Spectre Identifier - add backtick for global `define references
function (scope::CodeGenScope{Sim})(n::SNode{SC.Identifier}) where {Sim <: AbstractVerilogASimulator}
    identifier_str = String(n)
    identifier_sym = Symbol(lowercase(identifier_str))

    if needs_backtick(scope, identifier_sym)
        # Global parameter - needs backtick prefix
        print(scope.io, "`", identifier_str)
    else
        # Module parameter - use bare identifier
        print(scope.io, identifier_str)
    end
end

# Verilog-A handler for SPICE Model
# Generates two `define macros: one for the device type, one for parameters
# Prefixes identifiers with 'model_' to avoid naming conflicts (SPICE allows model names starting with digits)
function (scope::CodeGenScope{Sim})(n::SNode{SP.Model}) where {Sim <: AbstractVerilogASimulator}
    # Skip leading trivia (comments) for Verilog-A

    model_name_orig = String(n.name)
    model_name = "model_" * lowercase(model_name_orig)
    device_type = String(n.typ)
    va_module = spice_device_type_to_va_module(device_type)

    # Generate type macro: `define model_<name>_type <va_module>
    println(scope.io, "`define ", model_name, "_type ", va_module)

    # Generate params macro: `define model_<name>_params .PARAM1(val1), .PARAM2(val2), ...
    print(scope.io, "`define ", model_name, "_params ")

    multiline = should_format_multiline(n.parameters)
    first_param = true
    for param in n.parameters
        if !first_param
            print(scope.io, ", ")
        end

        if multiline
            # Each parameter on its own line for readability
            # Need backslash continuation for `define directives
            if !first_param
                println(scope.io, "\\")
                print(scope.io, "  ")  # Indent continuation
            end
        end

        param_name = uppercase(String(param.name))
        print(scope.io, ".", param_name, "(")

        if param.val !== nothing
            scope(param.val)
        end

        print(scope.io, ")")
        first_param = false
    end

    println(scope.io)
    println(scope.io)  # Extra blank line after macro definitions
end

# Verilog-A handler for SPICE Subcircuit
# Generates Verilog-A module with electrical ports and parameter declarations
function (scope::CodeGenScope{Sim})(n::SNode{SP.Subckt}) where {Sim <: AbstractVerilogASimulator}
    subckt_name = String(n.name)

    # Create child scope for this module
    child_scope = create_child_scope(scope)

    # Add subcircuit header parameters to child scope
    for par in n.parameters
        param_name_str = String(par.name)
        param_name_sym = Symbol(lowercase(param_name_str))
        add_param(child_scope, param_name_sym)
    end

    # Module header: module <name>(<ports>);
    print(scope.io, "module ", subckt_name, "(")

    # Collect port names
    port_names = String[]
    for node in n.subckt_nodes
        push!(port_names, String(node))
    end

    print(scope.io, join(port_names, ", "))
    println(scope.io, ");")

    # Port direction declarations: inout port1, port2, ...;
    print(scope.io, "  inout ")
    println(scope.io, join(port_names, ", "), ";")

    # Electrical discipline declarations: electrical port1, port2, ...;
    print(scope.io, "  electrical ")
    println(scope.io, join(port_names, ", "), ";")

    # Parameter declarations from subcircuit header
    if !isempty(n.parameters)
        println(scope.io)
        for par in n.parameters
            param_name_str = String(par.name)
            print(scope.io, "  parameter real ", param_name_str, " = ")
            if par.val !== nothing
                child_scope(par.val)
            else
                print(scope.io, "0")
            end
            println(scope.io, ";")
        end
    end

    println(scope.io)

    # Body statements (with child scope and increased indent)
    inner_scope = with_indent(child_scope, 1)
    for stmt in n.stmts
        inner_scope(stmt)
    end

    # End module
    println(scope.io, "endmodule")
    println(scope.io)  # Extra blank line after module
end

# Verilog-A handler for SPICE expression wrappers - convert {expr} and 'expr' to (expr)
function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.Brace, SP.Prime}}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, "(")
    scope(n.inner)
    print(scope.io, ")")
end

# Verilog-A handler for SPICE condition expressions
function (scope::CodeGenScope{Sim})(n::SNode{SP.Condition}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, "(")
    scope(n.body)
    print(scope.io, ")")
end

# Verilog-A handler for SPICE .if/.else/.endif blocks
function (scope::CodeGenScope{Sim})(n::SNode{SP.IfBlock}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)
    println(scope.io, "generate")

    inner_scope = with_indent(scope, 1)

    for (i, case_node) in enumerate(n.cases)
        if i == 1
            # First case - must be .if with condition
            write_indent(inner_scope)
            print(scope.io, "if ")
            scope(case_node.condition)
            println(scope.io, " begin")
        elseif case_node.condition !== nothing
            # Subsequent case with condition - .elseif
            write_indent(inner_scope)
            print(scope.io, "end else if ")
            scope(case_node.condition)
            println(scope.io, " begin")
        else
            # Case without condition - .else
            write_indent(inner_scope)
            println(scope.io, "end else begin")
        end

        # Process statements in this case
        case_inner_scope = with_indent(inner_scope, 1)
        for stmt in case_node.stmts
            case_inner_scope(stmt)
        end
    end

    write_indent(inner_scope)
    println(scope.io, "end")
    write_indent(scope)
    println(scope.io, "endgenerate")
end

# Verilog-A handler for SPICE Resistor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Resistor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = String(n.pos)
    neg_node = String(n.neg)

    # resistor #(.r(<value>)) <name> (<pos>, <neg>);
    print(scope.io, "resistor #(.r(")

    if n.val !== nothing
        scope(n.val)
    end

    print(scope.io, ")) ", inst_name, " (", pos_node, ", ", neg_node, ");")
    println(scope.io)
end

# Verilog-A handler for SPICE Capacitor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Capacitor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = String(n.pos)
    neg_node = String(n.neg)

    # capacitor #(.c(<value>)) <name> (<pos>, <neg>);
    print(scope.io, "capacitor #(.c(")

    if n.val !== nothing
        scope(n.val)
    end

    print(scope.io, ")) ", inst_name, " (", pos_node, ", ", neg_node, ");")
    println(scope.io)
end

# Verilog-A handler for SPICE Inductor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Inductor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = String(n.pos)
    neg_node = String(n.neg)

    # inductor #(.l(<value>)) <name> (<pos>, <neg>);
    print(scope.io, "inductor #(.l(")

    if n.val !== nothing
        scope(n.val)
    end

    print(scope.io, ")) ", inst_name, " (", pos_node, ", ", neg_node, ");")
    println(scope.io)
end

# Verilog-A handler for SPICE Diode
function (scope::CodeGenScope{Sim})(n::SNode{SP.Diode}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = String(n.pos)
    neg_node = String(n.neg)
    model_name_orig = String(n.model)
    model_name = "model_" * lowercase(model_name_orig)

    # `model_<name>_type #(`model_<name>_params) <name> (<pos>, <neg>);
    print(scope.io, "`", model_name, "_type #(`", model_name, "_params")

    # Add instance parameters if present
    if !isempty(n.params)
        for param in n.params
            print(scope.io, ", ")
            param_name = lowercase(String(param.name))
            print(scope.io, ".", param_name, "(")

            if param.val !== nothing
                scope(param.val)
            end

            print(scope.io, ")")
        end
    end

    print(scope.io, ") ", inst_name, " (", pos_node, ", ", neg_node, ");")
    println(scope.io)
end

# Verilog-A handler for SPICE OSDI Device (N prefix - OpenVAF/OSDI models, Y prefix - Xyce ADMS models)
# Uses model macro convention like Diode but with variable nodes like SubcktCall
function (scope::CodeGenScope{Sim})(n::SNode{SP.OSDIDevice}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    model_name_orig = String(n.model)
    model_name = "model_" * lowercase(model_name_orig)

    # Collect node names
    node_names = String[]
    for node in n.nodes
        push!(node_names, String(node))
    end

    if startswith(lowercase(inst_name), "y")
        # Xyce OSDI device:
        # Y<module name> <unique instance name>  <node>* <model name> <instance parameter list>
        inst_name = popfirst!(node_names)
    end

    # `model_<name>_type #(`model_<name>_params, .param1(val1), ...) <name> (nodes...);
    multiline = should_format_multiline(n.parameters)

    print(scope.io, "`", model_name, "_type #(")
    if multiline
        println(scope.io)
        write_indent(scope)
        print(scope.io, "  `", model_name, "_params")
    else
        print(scope.io, "`", model_name, "_params")
    end

    # Add instance parameters if present
    if !isempty(n.parameters)
        for param in n.parameters
            print(scope.io, ",")

            if multiline
                println(scope.io)
                write_indent(scope)
                print(scope.io, "  ")  # Indent parameters
            else
                print(scope.io, " ")
            end

            param_name = uppercase(String(param.name))
            print(scope.io, ".", param_name, "(")

            if param.val !== nothing
                scope(param.val)
            end

            print(scope.io, ")")
        end
    end

    if multiline
        println(scope.io)
        write_indent(scope)
    end
    print(scope.io, ") ", inst_name, " (", join(node_names, ", "), ");")
    println(scope.io)
end

# Verilog-A handler for SPICE Subcircuit Call
function (scope::CodeGenScope{Sim})(n::SNode{SP.SubcktCall}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    subckt_name = String(n.model)

    # Collect node names
    node_names = String[]
    for node in n.nodes
        push!(node_names, String(node))
    end

    # <subckt_name> #(.param1(value1), ...) <inst_name>(<nodes>);
    print(scope.io, subckt_name)

    # Add parameter overrides if present
    if !isempty(n.parameters)
        multiline = should_format_multiline(n.parameters)
        print(scope.io, " #(")

        first_param = true
        for param in n.parameters
            if !first_param
                print(scope.io, ",")
            end

            if multiline
                println(scope.io)
                write_indent(scope)
                print(scope.io, "  ")  # Indent parameters
            else
                if !first_param
                    print(scope.io, " ")
                end
            end

            param_name = uppercase(String(param.name))
            print(scope.io, ".", param_name, "(")
            if param.val !== nothing
                scope(param.val)
            end
            print(scope.io, ")")
            first_param = false
        end

        if multiline
            println(scope.io)
            write_indent(scope)
        end
        print(scope.io, ")")
    end

    print(scope.io, " ", inst_name, "(")
    print(scope.io, join(node_names, ", "))
    print(scope.io, ");")

    println(scope.io)
end

# Verilog-A handler for SPICE Netlist Source
# Two-pass approach: first emit includes and model macros, then emit modules
function (scope::CodeGenScope{Sim})(n::SNode{SP.SPICENetlistSource}) where {Sim <: AbstractVerilogASimulator}
    # Emit standard Verilog-A includes
    println(scope.io, "`include \"disciplines.vams\"")
    println(scope.io)

    # First pass: collect and emit model definitions as macros
    for stmt in n.stmts
        if stmt isa SNode{SP.Model}
            scope(stmt)
        end
    end

    # Second pass: emit subcircuits as modules (skip models, titles handled by no-op)
    for stmt in n.stmts
        # Skip Model statements (already emitted in first pass)
        if !(stmt isa SNode{SP.Model})
            scope(stmt)
        end
    end
end

# Export simulator types and traits from this module
export AbstractSimulator, AbstractSpiceSimulator, AbstractSpectreSimulator, AbstractVerilogASimulator
export Ngspice, Hspice, Pspice, Xyce, SpectreADE, OpenVAF, Gnucap
export language, hasdocprops, doc_only_params, temperature_param_mapping
export symbol_from_simulator, simulator_from_symbol
