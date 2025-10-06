# SPICE/Spectre Code Generator
#
# This module provides functionality to generate SPICE/Spectre netlists from parsed ASTs.
# It mirrors the structure of src/spectre.jl but generates netlist code instead of Julia code.
#
# Key design:
# - Parametric CodeGenScope{Lang, Dialect} for language/dialect-specific generation
# - Default implementation preserves original formatting via String(node)
# - Override specific node types for dialect conversion and parameter filtering
# - Non-recursive (single file) - caller handles include/lib traversal

# Import types from parent module - reuse parent's imports
import ..SNode, ..SC, ..SP

# Import RedTree utilities
using ..SpectreNetlistParser.RedTree: fullcontents

# Import error checking
using ..SpectreNetlistParser: visit_errors

"""
    CodeGenScope{Lang, Dialect}

Scope for generating SPICE/Spectre code from AST.

Type parameters:
- `Lang`: Language symbol (`:spice` or `:spectre`)
- `Dialect`: Dialect symbol (`:ngspice`, `:hspice`, `:pspice`, `:spectre`, etc.)

Fields:
- `io`: Output IO buffer
- `indent`: Current indentation level (for readability)
- `options`: Dict for dialect-specific options

The parametric type allows method specialization for different language/dialect combinations:
```julia
(scope::CodeGenScope{:spice, :ngspice})(node::SNode{SP.MOSFET})  # ngspice-specific MOSFET
(scope::CodeGenScope{:spectre, :spectre})(node::SNode{SC.Instance})  # Spectre instance
```
"""
struct CodeGenScope{Lang, Dialect}
    io::IO
    indent::Int
    options::Dict{Symbol, Any}
end

# Constructor with default options
function CodeGenScope{Lang, Dialect}(io::IO, indent::Int=0) where {Lang, Dialect}
    CodeGenScope{Lang, Dialect}(io, indent, Dict{Symbol, Any}())
end

# Helper to create new scope with modified indent
with_indent(scope::CodeGenScope{L, D}, delta::Int) where {L, D} =
    CodeGenScope{L, D}(scope.io, scope.indent + delta, scope.options)

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

WARNING: This fallback may prevent proper conversion and can cause issues with
whitespace accumulation in roundtrip tests. Consider adding an explicit handler
that recurses into the node's children.
"""
function (scope::CodeGenScope)(node::SNode{T}) where T
    # Warn that we're using fullcontents fallback - indicates missing handler
    # This won't be called for Terminals since they have explicit handlers
    if get(scope.options, :warn_fallback, true)
        @warn "Using fullcontents() fallback for node type $T. Consider adding an explicit handler." maxlog=1 _id=hash(T)
    end

    # Default: preserve original formatting with fullcontents
    # This won't recurse into children - it's a literal copy
    print(scope.io, fullcontents(node))
end

# Handle nothing nodes gracefully
(scope::CodeGenScope)(::Nothing) = nothing

# =============================================================================
# Source and Block Nodes - Recurse into children
# =============================================================================

"""
Process top-level SPICE netlist source.
"""
function (scope::CodeGenScope)(n::SNode{SP.SPICENetlistSource})
    for stmt in n.stmts
        scope(stmt)
    end
end

"""
Process top-level Spectre netlist source.
"""
function (scope::CodeGenScope)(n::SNode{SC.SpectreNetlistSource})
    for stmt in n.stmts
        scope(stmt)
    end
end

"""
Process block statements (subcircuits, lib sections, etc.)
"""
function (scope::CodeGenScope)(n::SNode{<:Union{SC.AbstractBlockASTNode, SP.AbstractBlockASTNode}})
    for stmt in n.stmts
        scope(stmt)
    end
end

# =============================================================================
# Terminal Nodes - Direct String Conversion
# =============================================================================

# Terminals use String(node) to get semantic content without trivia
function (scope::CodeGenScope)(n::SNode{<:SP.Terminal})
    print(scope.io, String(n))
end

function (scope::CodeGenScope)(n::SNode{<:SC.Terminal})
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

function (scope::CodeGenScope)(n::SNode{SC.SpectreArray})
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
function (scope::CodeGenScope)(n::SNode{SP.NodeName})
    scope(n.name)  # name is Terminal (Identifier or NumberLiteral)
end

# SPICE HierarchialNode: node names with optional subnodes (e.g., "vdd", "n1", "foo.bar")
function (scope::CodeGenScope)(n::SNode{SP.HierarchialNode})
    scope(n.base)
    for subnode in n.subnodes
        scope(subnode)
    end
end

# Spectre SNode: node reference with optional subcircuit qualifiers
function (scope::CodeGenScope)(n::SNode{SC.SNode})
    for subckt in n.subckts
        scope(subckt)
    end
    scope(n.node)  # node is Terminal (Identifier or NumberLiteral)
end

# =============================================================================
# Title and Braces
# =============================================================================

# SPICE Title: first line of SPICE file (optional .title keyword + comment line)
function (scope::CodeGenScope)(n::SNode{SP.Title})
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
function (scope::CodeGenScope)(n::SNode{SP.Brace})
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
function (scope::CodeGenScope)(n::SNode{SP.ParamStatement})
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

# SPICE .model name type param1=val1 param2=val2 ...
function (scope::CodeGenScope)(n::SNode{SP.Model})
    print(scope.io, ".model ")
    scope(n.name)
    print(scope.io, " ")
    scope(n.typ)
    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# Spectre: model name master_name param1=val1 param2=val2
function (scope::CodeGenScope)(n::SNode{SC.Model})
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
function (scope::CodeGenScope)(n::SNode{SP.Subckt})
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
function (scope::CodeGenScope)(n::SNode{SC.Subckt})
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
function (scope::CodeGenScope)(n::SNode{SP.MOSFET})
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
function (scope::CodeGenScope)(n::SNode{SP.Resistor})
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
function (scope::CodeGenScope)(n::SNode{SP.Capacitor})
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
function (scope::CodeGenScope)(n::SNode{SP.Inductor})
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
function (scope::CodeGenScope)(n::SNode{SP.Diode})
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
function (scope::CodeGenScope)(n::SNode{SP.Voltage})
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
function (scope::CodeGenScope)(n::SNode{SP.Current})
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
function (scope::CodeGenScope)(n::SNode{SP.SubcktCall})
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
function (scope::CodeGenScope)(n::SNode{SC.Instance})
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
# Dialect-Specific Specializations
# =============================================================================

# ngspice documentation-only model parameters to filter out
# These parameters are for documentation and are not recognized by ngspice
const NGSPICE_DOC_ONLY_PARAMS = Set{Symbol}([
    :iave,      # Average current (documentation)
    :vpk,       # Peak voltage (documentation)
    :mfg,       # Manufacturer code (documentation)
    :type,      # Device type description (documentation)
    :icrating,  # Current rating (documentation)
    :vceo,      # Collector-emitter voltage (documentation)
])

# ngspice-specific Model handler - filters documentation-only parameters
function (scope::CodeGenScope{:spice, :ngspice})(n::SNode{SP.Model})
    print(scope.io, ".model ")
    scope(n.name)
    print(scope.io, " ")
    scope(n.typ)
    for param in n.parameters
        param_name = lowercase(String(param.name))
        if Symbol(param_name) ∉ NGSPICE_DOC_ONLY_PARAMS
            print(scope.io, " ")
            scope(param)
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
    generate_code(ast::SNode, lang::Symbol, dialect::Symbol; options::Dict=Dict()) -> String

Generate SPICE/Spectre code from parsed AST.

Arguments:
- `ast`: Parsed netlist AST (from SpectreNetlistParser)
- `lang`: Target language (`:spice` or `:spectre`)
- `dialect`: Target dialect (`:ngspice`, `:hspice`, `:pspice`, `:spectre`, etc.)
- `options`: Optional dialect-specific options

Returns:
- Generated code as String

Note: If the AST contains parse errors, a warning will be printed. Error lines will
be preserved as-is without reformatting.

Example:
```julia
# Parse SPICE file
ast = SpectreNetlistParser.parsefile("input.sp")

# Generate different dialects
spectre_code = generate_code(ast, :spectre, :spectre)
hspice_code = generate_code(ast, :spice, :hspice)
```
"""
function generate_code(ast::SNode, lang::Symbol, dialect::Symbol; options::Dict=Dict{Symbol, Any}())
    # Check for parse errors and warn user
    if ast.ps.errored
        @warn "AST contains parse errors. Error lines will not be reformatted."
        visit_errors(ast; io=stderr)
    end

    io = IOBuffer()
    scope = CodeGenScope{lang, dialect}(io, 0, options)
    scope(ast)
    return String(take!(io))
end

"""
    generate_code(ast::SNode, io::IO, lang::Symbol, dialect::Symbol; options::Dict=Dict())

Generate SPICE/Spectre code to an IO stream.

Arguments:
- `ast`: Parsed netlist AST
- `io`: Output IO stream
- `lang`: Target language
- `dialect`: Target dialect
- `options`: Optional dialect-specific options

Note: If the AST contains parse errors, a warning will be printed. Error lines will
be preserved as-is without reformatting.

Example:
```julia
open("output.scs", "w") do io
    generate_code(ast, io, :spectre, :spectre)
end
```
"""
function generate_code(ast::SNode, io::IO, lang::Symbol, dialect::Symbol; options::Dict=Dict{Symbol, Any}())
    # Check for parse errors and warn user
    if ast.ps.errored
        @warn "AST contains parse errors. Error lines will not be reformatted."
        visit_errors(ast; io=stderr)
    end

    scope = CodeGenScope{lang, dialect}(io, 0, options)
    scope(ast)
end

export CodeGenScope, generate_code, write_indent, write_terminal, newline, with_indent
