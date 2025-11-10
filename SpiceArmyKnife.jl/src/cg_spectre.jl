# Spectre Code Generator
#
# Spectre-specific code generation methods for CodeGenScope{<:AbstractSpectreSimulator}
# This file contains all handlers that are specific to Spectre simulators
# (SpectreADE, etc.)

# =============================================================================
# Spectre Terminal Nodes
# =============================================================================

# Terminal handlers - only for Spectre to Spectre conversions
function (scope::CodeGenScope{Sim})(n::SNode{<:SC.Terminal}) where {Sim <: AbstractSpectreSimulator}
    print(scope.io, String(n))
end

# =============================================================================
# Spectre Node References
# =============================================================================

# Spectre SNode: node reference with optional subcircuit qualifiers
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SC.SNode})
    for subckt in n.subckts
        scope(subckt)
    end
    scope(n.node)  # node is Terminal (Identifier or NumberLiteral)
end

# =============================================================================
# Spectre Arrays
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
# Spectre Models
# =============================================================================

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
# Spectre Subcircuits
# =============================================================================

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

    # Generate binned models at end of subcircuit (if simulator doesn't support binning)
    generate_binned_models(scope)

    # End
    print(scope.io, "ends")
    if n.end_name !== nothing
        # VACASK doesn't support subcircuit name after ends - make it a comment
        # Standard Spectre uses: ends subckt_name
        if scope isa CodeGenScope{VACASK}
            print(scope.io, " // ")
        else
            print(scope.io, " ")
        end
        scope(n.end_name)
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
# SPICE to Spectre Conversion - Helper Functions
# =============================================================================

"""
    format_node_list(scope::CodeGenScope, nodes) -> String

Format a list of nodes as Spectre-style parenthesized list: (n1 n2 n3)
"""
function format_node_list(scope::CodeGenScope, nodes)
    buf = IOBuffer()
    print(buf, "(")
    first = true
    for node in nodes
        if !first
            print(buf, " ")
        end
        # Create temporary scope to render node
        temp_scope = CodeGenScope{typeof(scope).parameters[1]}(buf, 0, scope.options, scope.params, scope.parent_scope,
                                                                 scope.includepaths, scope.processed_includes, scope.current_output_file)
        temp_scope(node)
        first = false
    end
    print(buf, ")")
    return String(take!(buf))
end

"""
    render_value(scope::CodeGenScope, val) -> String

Render a parameter value (handles both SNode and String/Number types).
"""
function render_value(scope::CodeGenScope, val)
    buf = IOBuffer()
    temp_scope = CodeGenScope{typeof(scope).parameters[1]}(buf, 0, scope.options, scope.params, scope.parent_scope,
                                                             scope.includepaths, scope.processed_includes, scope.current_output_file)
    temp_scope(val)
    return String(take!(buf))
end

# =============================================================================
# SPICE to Spectre Conversion - Terminal and Node Handlers
# =============================================================================

# SPICE Terminal nodes - direct string conversion (Spectre accepts same syntax)
function (scope::CodeGenScope{Sim})(n::SNode{<:SP.Terminal}) where {Sim <: AbstractSpectreSimulator}
    print(scope.io, String(n))
end

# SPICE NodeName: base node name
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.NodeName})
    scope(n.name)
end

# SPICE HierarchialNode: node with optional subnodes (base.sub1.sub2...)
# Dots are valid in Spectre identifiers, so just output the whole thing
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.HierarchialNode})
    print(scope.io, String(n))
end

# =============================================================================
# SPICE to Spectre Conversion - Expression Handlers
# =============================================================================

# SPICE Brace: {expr} → expr (Spectre doesn't use braces for expressions)
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Brace})
    scope(n.inner)
end

# SPICE Prime: 'expr' → expr (Spectre doesn't use primes)
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Prime})
    scope(n.inner)
end

# SPICE Condition: preserve as-is
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Condition})
    print(scope.io, "(")
    scope(n.body)
    print(scope.io, ")")
end

# =============================================================================
# SPICE to Spectre Conversion - Structural Elements
# =============================================================================

# SPICE Netlist Source: detect library sections and wrap if needed
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.SPICENetlistSource})
    # First pass: check if this file contains any library sections
    has_lib_sections = any(stmt -> isa(stmt, SNode{SP.LibStatement}), n.stmts)

    # If file contains library sections, wrap with library...endlibrary
    if has_lib_sections
        # Use filename (without extension) as library name, or "lib" as fallback
        lib_name = get(scope.options, :library_name, "lib")

        println(scope.io, "library ", lib_name)
        println(scope.io)
    end

    # Process all statements
    for stmt in n.stmts
        scope(stmt)
    end

    # Generate binned models at end of file (if simulator doesn't support binning)
    # This handles top-level models outside library sections
    generate_binned_models(scope)

    # Close library wrapper if needed
    if has_lib_sections
        println(scope.io)
        println(scope.io, "endlibrary ", lib_name)
    end
end

# SPICE Title: convert to comment
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Title})
    print(scope.io, "// ")
    scope(n.line)
    scope(n.nl)
end

# SPICE End statement: skip (Spectre doesn't need .end)
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.EndStatement})
    # No-op: Spectre doesn't use .end statements
    nothing
end

# SPICE Subcircuit: .subckt name n1 n2 → subckt name (n1 n2)
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Subckt})
    print(scope.io, "subckt ")
    scope(n.name)

    # Nodes in parentheses
    if !isempty(n.subckt_nodes)
        print(scope.io, " ")
        print(scope.io, format_node_list(scope, n.subckt_nodes))
    end
    println(scope.io)

    # Output parameters as separate parameters line (if any)
    if !isempty(n.parameters)
        print(scope.io, "parameters")
        for param in n.parameters
            print(scope.io, " ")
            scope(param)
        end
        println(scope.io)
    end

    # Body statements
    for stmt in n.stmts
        scope(stmt)
    end

    # Generate binned models at end of subcircuit (if simulator doesn't support binning)
    generate_binned_models(scope)

    # End
    print(scope.io, "ends")
    if n.name_end !== nothing
        # VACASK doesn't support subcircuit name after ends - make it a comment
        # Standard Spectre uses: ends subckt_name
        if scope isa CodeGenScope{VACASK}
            print(scope.io, " // ")
        else
            print(scope.io, " ")
        end
        scope(n.name_end)
    end
    println(scope.io)
end

# =============================================================================
# Helper Functions for Binning
# =============================================================================

# hasparam is defined in cg_veriloga.jl

"""
    build_param_dict(params) -> Dict{Symbol, Union{Float64, String, Nothing}}

Build a dictionary of parameter names to their values (case-insensitive keys).
Returns Float64 for numeric values, String for non-numeric values, and nothing for missing values.
"""
function build_param_dict(params)
    param_dict = Dict{Symbol, Union{Float64, String, Nothing}}()
    for p in params
        param_name = Symbol(lowercase(String(p.name)))
        if p.val !== nothing
            val_str = String(p.val)
            try
                param_dict[param_name] = parse(Float64, val_str)
            catch
                param_dict[param_name] = val_str
            end
        else
            param_dict[param_name] = nothing
        end
    end
    return param_dict
end

"""
    is_binned_model(param_dict::Dict{Symbol, Union{Float64, String, Nothing}}) -> Bool

Check if a model has binning parameters (LMIN, LMAX, WMIN, WMAX) with numeric values.
"""
function is_binned_model(param_dict::Dict{Symbol, Union{Float64, String, Nothing}})
    return haskey(param_dict, :lmin) && haskey(param_dict, :lmax) &&
           haskey(param_dict, :wmin) && haskey(param_dict, :wmax) &&
           param_dict[:lmin] !== nothing && param_dict[:lmax] !== nothing &&
           param_dict[:wmin] !== nothing && param_dict[:wmax] !== nothing
end

"""
    get_model_base_name(model_name::String) -> String

Strip numeric suffix from model name for binning.
Example: "nmos.1" → "nmos", "pmos_10" → "pmos"
"""
function get_model_base_name(model_name::String)
    # Match patterns like .N or _N at the end
    m = match(r"^(.+)[._](\d+)$", model_name)
    if m !== nothing
        return m.captures[1]
    end
    return model_name
end

# SPICE Model: .model name type params → model name type params
# If simulator doesn't support binning, accumulate binned models for later generation
function (scope::CodeGenScope{Sim})(n::SNode{SP.Model}) where {Sim <: AbstractSpectreSimulator}
    # Build parameter dict once for efficient lookups
    param_dict = build_param_dict(n.parameters)

    # Check if simulator supports binning - if not, detect and accumulate binned models
    if !binningsupport(Sim())
        # Check if this model has binning parameters
        if is_binned_model(param_dict)
            # Extract binning parameter values (guaranteed to be non-nothing by is_binned_model)
            lmin = param_dict[:lmin]
            lmax = param_dict[:lmax]
            wmin = param_dict[:wmin]
            wmax = param_dict[:wmax]

            # Get or create binned_models dict in options
            binned_models = get!(scope.options, :binned_models, Dict{Symbol, Vector{Tuple{Float64, Float64, Float64, Float64, SNode{SP.Model}}}}())

            # Get base model name (strip .N or _N suffix)
            model_name = String(n.name)
            base_name = Symbol(get_model_base_name(model_name))

            # Add this bin to the vector for this base model
            bins = get!(binned_models, base_name, Vector{Tuple{Float64, Float64, Float64, Float64, SNode{SP.Model}}}())
            push!(bins, (lmin, lmax, wmin, wmax, n))

            # Don't output the model yet - it will be output as unified binned model later
            return
        end
    end

    # Non-binned model (or simulator has binning support): output normally
    print(scope.io, "model ")
    scope(n.name)
    print(scope.io, " ")

    # Map SPICE device type to simulator-specific model name
    device_type = String(n.typ)
    level = get(param_dict, :level, nothing)
    version = get(param_dict, :version, nothing)

    # Get mapped model name using device mapping system
    model_name, type_params = spice_device_type_to_model_name(scope, device_type, level, version)
    print(scope.io, model_name)

    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

"""
    generate_binned_models(scope::CodeGenScope{Sim}) where {Sim <: AbstractSpectreSimulator}

Generate if-expression binning logic for all accumulated binned models.
This should be called at the end of block processing (subcircuit, library section, file)
for simulators that don't have built-in binning support.

For simulators with binning support, this is a no-op.
"""
function generate_binned_models(scope::CodeGenScope{Sim}) where {Sim <: AbstractSpectreSimulator}
    # Only generate if simulator doesn't support binning
    if binningsupport(Sim())
        return  # Simulator has built-in binning, no code generation needed
    end
    # Check if we have any binned models accumulated
    binned_models = get(scope.options, :binned_models, nothing)
    if binned_models === nothing || isempty(binned_models)
        return  # No binned models to generate
    end

    # Generate if-expressions for each binned model group
    for (base_name, bins) in binned_models
        if isempty(bins)
            continue
        end

        # Sort bins by lmin, wmin for consistent output
        sorted_bins = sort(bins, by = b -> (b[1], b[3]))  # Sort by lmin, then wmin

        # Generate if-expression with all bins
        for (i, (lmin, lmax, wmin, wmax, model_node)) in enumerate(sorted_bins)
            # Generate condition
            if i == 1
                if Sim === VACASK
                    println(scope.io, "@if l >= ", lmin, " && l < ", lmax, " && w >= ", wmin, " && w < ", wmax)
                else
                    print(scope.io, "if (l >= ", lmin, " && l < ", lmax, " && w >= ", wmin, " && w < ", wmax, ") {\n")
                end
            else
                if Sim === VACASK
                    println(scope.io, "@elseif l >= ", lmin, " && l < ", lmax, " && w >= ", wmin, " && w < ", wmax)
                else
                    print(scope.io, "} else if (l >= ", lmin, " && l < ", lmax, " && w >= ", wmin, " && w < ", wmax, ") {\n")
                end
            end

            # Generate model line with base name (no .N suffix)
            print(scope.io, "    model ", base_name, " ")

            # Map SPICE device type to simulator-specific model name
            param_dict = build_param_dict(model_node.parameters)
            device_type = String(model_node.typ)
            level = get(param_dict, :level, nothing)
            version = get(param_dict, :version, nothing)

            model_name, type_params = spice_device_type_to_model_name(scope, device_type, level, version)
            print(scope.io, model_name)

            # Output all parameters (including binning params for now)
            for param in model_node.parameters
                print(scope.io, " ")
                scope(param)
            end
            println(scope.io)
        end

        # Close the if-expression
        if Sim === VACASK
            println(scope.io, "@end")
        else
            println(scope.io, "}")
        end
        println(scope.io)
    end

    # Clear the accumulated binned models after generation
    empty!(binned_models)
end

# SPICE Parameter statement: .param x=1 → parameters x=1
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.ParamStatement})
    print(scope.io, "parameters ")
    first = true
    for param in n.params
        if !first
            print(scope.io, " ")
        end
        scope(param)
        first = false
    end
    println(scope.io)
end

# =============================================================================
# SPICE to Spectre Conversion - Device Instances
# =============================================================================

# SPICE Resistor: R1 n1 n2 val → R1 (n1 n2) resistor r=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Resistor})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))

    # Check if this is a model-based resistor or value-based
    has_r_param = any(p -> lowercase(String(p.name)) == "r", n.params)

    if has_r_param || n.val === nothing
        # Model-based or parameter-based resistor
        if n.val !== nothing
            print(scope.io, " ")
            scope(n.val)  # Model name
        else
            print(scope.io, " resistor")
        end
        for param in n.params
            print(scope.io, " ")
            scope(param)
        end
    else
        # Simple value-based resistor
        print(scope.io, " resistor r=")
        scope(n.val)
    end
    println(scope.io)
end

# SPICE Capacitor: C1 n1 n2 val → C1 (n1 n2) capacitor c=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Capacitor})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))

    # Check if this is a model-based capacitor or value-based
    has_c_param = any(p -> lowercase(String(p.name)) == "c", n.params)

    if has_c_param || n.val === nothing
        # Model-based or parameter-based capacitor
        if n.val !== nothing
            print(scope.io, " ")
            scope(n.val)  # Model name
        else
            print(scope.io, " capacitor")
        end
        for param in n.params
            print(scope.io, " ")
            scope(param)
        end
    else
        # Simple value-based capacitor
        print(scope.io, " capacitor c=")
        scope(n.val)
    end
    println(scope.io)
end

# SPICE Inductor: L1 n1 n2 val → L1 (n1 n2) inductor l=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Inductor})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))

    # Check if this is a model-based inductor or value-based
    has_l_param = any(p -> lowercase(String(p.name)) == "l", n.params)

    if has_l_param || n.val === nothing
        # Model-based or parameter-based inductor
        if n.val !== nothing
            print(scope.io, " ")
            scope(n.val)  # Model name
        else
            print(scope.io, " inductor")
        end
        for param in n.params
            print(scope.io, " ")
            scope(param)
        end
    else
        # Simple value-based inductor
        print(scope.io, " inductor l=")
        scope(n.val)
    end
    println(scope.io)
end

# SPICE Diode: D1 n1 n2 model → D1 (n1 n2) model
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Diode})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))
    print(scope.io, " ")
    scope(n.model)

    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Bipolar Transistor: Q1 c b e [s] [t] model → Q1 (c b e [s] [t]) model
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.BipolarTransistor})
    scope(n.name)
    print(scope.io, " ")

    # Collect nodes: c, b, e, and optionally s, t
    nodes = [n.c, n.b, n.e]
    if n.s !== nothing
        push!(nodes, n.s)
    end
    if n.t !== nothing
        push!(nodes, n.t)
    end

    print(scope.io, format_node_list(scope, nodes))
    print(scope.io, " ")
    scope(n.model)

    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE MOSFET: M1 d g s b model → M1 (d g s b) model
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.MOSFET})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.d, n.g, n.s, n.b]))
    print(scope.io, " ")
    scope(n.model)

    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Source specifications: DC, AC, TRAN
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.DCSource})
    # DC source: kw=DC, dcval=value
    if n.kw !== nothing
        print(scope.io, "dc")
        if n.eq !== nothing
            print(scope.io, "=")
        else
            print(scope.io, "=")
        end
    end
    scope(n.dcval)
end

function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.ACSource})
    # AC source: kw=AC, acmag=magnitude
    print(scope.io, "ac=")
    scope(n.acmag)
end

function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.TranSource})
    # Transient source: kw=type (SIN, PULSE, etc), values=list
    print(scope.io, lowercase(String(n.kw)), "(")
    first_val = true
    for val in n.values
        if !first_val
            print(scope.io, " ")
        end
        scope(val)
        first_val = false
    end
    print(scope.io, ")")
end

# SPICE Voltage Source: V1 n1 n2 DC val → V1 (n1 n2) vsource dc=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Voltage})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))
    print(scope.io, " vsource")

    # Process source specifications (DC, AC, TRAN)
    for val in n.vals
        print(scope.io, " ")
        scope(val)
    end
    println(scope.io)
end

# SPICE Current Source: I1 n1 n2 DC val → I1 (n1 n2) isource dc=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.Current})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, [n.pos, n.neg]))
    print(scope.io, " isource")

    # Process source specifications (DC, AC, TRAN)
    for val in n.vals
        print(scope.io, " ")
        scope(val)
    end
    println(scope.io)
end

# SPICE Subcircuit Call: X1 n1 n2 ... subckt → X1 (n1 n2 ...) subckt
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.SubcktCall})
    scope(n.name)
    print(scope.io, " ")
    print(scope.io, format_node_list(scope, n.nodes))
    print(scope.io, " ")
    scope(something(n.model, n.model_after))

    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# =============================================================================
# SPICE to Spectre Conversion - Function Calls
# =============================================================================

# SPICE FunctionCall handler for VACASK - map statistical functions to nominal value
# VACASK doesn't support gauss, agauss, aunif, unif, limit - return nominal value only
function (scope::CodeGenScope{VACASK})(n::SNode{SP.FunctionCall})
    func_name = lowercase(String(n.id))

    if func_name in ("gauss", "agauss", "aunif", "unif", "limit")
        # Statistical distribution functions not supported by VACASK
        # Return only the nominal/mean value (first argument)
        input_dialect = get(scope.options, :spice_dialect, :ngspice)
        nargs = length(n.args)

        if func_name in ("gauss", "agauss")
            # gauss(nom, rvar, sigma) → nom
            # agauss(nom, avar, sigma) → nom
            # Both dialects: first arg is always nominal value
            if nargs < 1
                error("$func_name() requires at least 1 argument for nominal value")
            end
            # For ngspice with 1 arg: gauss(sigma) defaults nom=1.0, but we already have 1 arg
            # For ngspice with 2+ args: first is nom
            # For Xyce: first is always nom (μ)
            if input_dialect == :ngspice && nargs == 1
                # Special case: gauss(sigma) → default nominal is 1.0
                print(scope.io, "1.0")
            else
                scope(n.args[1].item)
            end
        elseif func_name in ("aunif", "unif")
            # unif(nom, rvar) → nom
            # aunif(nom, avar) → nom
            if nargs < 1
                error("$func_name() requires at least 1 argument for nominal value")
            end
            scope(n.args[1].item)
        elseif func_name == "limit"
            # limit(nom, avar) → nom
            if nargs < 1
                error("limit() requires at least 1 argument for nominal value")
            end
            scope(n.args[1].item)
        end
    else
        # Regular function call - output with lowercase name
        print(scope.io, func_name, "(")
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
end

# =============================================================================
# SPICE to Spectre Conversion - Control Statements
# =============================================================================

# SPICE Include: .include "file.sp" → include "file.scs"
# Recursively processes included files with inherited scope, mirroring source directory structure
# - If output is a file: writes to separate .scs file, emits include directive
# - If output is memory (IOBuffer): inlines the content directly, no include directive
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.IncludeStatement})
    # Strip outer quotes from path (preserves escape sequences)
    path_str = strip(String(n.path), ['"', '\''])

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
                # Writing to file - mirror source directory structure in output
                source_root = get(scope.options, :source_root, dirname(fullpath))
                output_dir = get(scope.options, :output_dir, ".")

                # Compute relative path from source root to included file
                rel_from_source_root = relpath(fullpath, source_root)

                # Change extension and compute output path (mirrors source structure)
                output_relpath_from_root = splitext(rel_from_source_root)[1] * ".scs"
                output_path = joinpath(output_dir, output_relpath_from_root)

                # Create directory structure if needed (equivalent to mkdir -p)
                mkpath(dirname(output_path))

                # Create new scope for included file with file IO
                # Prepend directory of included file so nested includes resolve relative to it
                inc_includepaths = [dirname(fullpath), scope.includepaths...]
                open(output_path, "w") do inc_io
                    inc_scope = CodeGenScope{typeof(scope).parameters[1]}(inc_io, 0, scope.options, scope.params, scope.parent_scope,
                                                  inc_includepaths, scope.processed_includes, output_path)
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

    # Emit include directive only if writing to file (use relative path from current file to included file)
    if scope.io isa IOStream
        # Compute paths for relative include directive
        source_root = get(scope.options, :source_root, dirname(fullpath))
        output_dir = get(scope.options, :output_dir, ".")
        current_output_file = scope.current_output_file

        if current_output_file !== nothing
            # Compute output path for included file (mirrors source structure)
            rel_from_source_root = relpath(fullpath, source_root)
            output_relpath_from_root = splitext(rel_from_source_root)[1] * ".scs"
            included_output_path = joinpath(output_dir, output_relpath_from_root)

            # Emit relative path from current output file to included output file
            relative_include_path = relpath(included_output_path, dirname(current_output_file))
            println(scope.io, "include \"", relative_include_path, "\"")
        else
            # Fallback: use path_str with changed extension (shouldn't happen for file output)
            output_relpath = splitext(path_str)[1] * ".scs"
            println(scope.io, "include \"", output_relpath, "\"")
        end
    end
    # If IOBuffer: content already inlined, no directive needed
end

# SPICE Library Block: .lib name → Spectre section name
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.LibStatement})
    lib_name = String(n.name)

    # Spectre library syntax: section sectionName ... endsection [sectionName]
    println(scope.io, "section ", lib_name)

    # Process body statements
    for stmt in n.stmts
        scope(stmt)
    end

    # Generate binned models at end of library section (if simulator doesn't support binning)
    generate_binned_models(scope)

    println(scope.io, "endsection ", lib_name)
    println(scope.io)
end

# SPICE Global: .global vdd gnd → global vdd gnd
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.GlobalStatement})
    print(scope.io, "global")
    for node in n.nodes
        print(scope.io, " ")
        scope(node)
    end
    println(scope.io)
end

# SPICE If Block: .if condition → Spectre conditional instantiation
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.IfBlock})
    # Spectre uses if/else blocks with braces for conditional instantiation (model binning)
    for (i, case_node) in enumerate(n.cases)
        if i == 1
            # First case - .if
            print(scope.io, "if (")
            scope(case_node.condition)
            println(scope.io, ") {")
        elseif case_node.condition !== nothing
            # .elseif
            print(scope.io, "} else if (")
            scope(case_node.condition)
            println(scope.io, ") {")
        else
            # .else
            println(scope.io, "} else {")
        end

        # Process statements
        for stmt in case_node.stmts
            scope(stmt)
        end
    end

    println(scope.io, "}")
end

# VACASK If Block: .if condition → @if-@elseif-@else-@end
function (scope::CodeGenScope{VACASK})(n::SNode{SP.IfBlock})
    for (i, case_node) in enumerate(n.cases)
        if i == 1
            # First case - .if
            print(scope.io, "@if ")
            scope(case_node.condition)
            println(scope.io)
        elseif case_node.condition !== nothing
            # .elseif
            print(scope.io, "@elseif ")
            scope(case_node.condition)
            println(scope.io)
        else
            # .else
            println(scope.io, "@else")
        end

        # Process statements
        for stmt in case_node.stmts
            scope(stmt)
        end
    end

    println(scope.io, "@end")
end

# =============================================================================
# SPICE to Spectre Conversion - Analysis and Options
# =============================================================================

# SPICE Option: .option opt=val → simulatorOptions options opt=val
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.OptionStatement})
    print(scope.io, "simulatorOptions options")

    # Process option parameters
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

function (scope::CodeGenScope{VACASK})(n::SNode{SP.OptionStatement})
    print(scope.io, "// simulatorOptions options")

    # Process option parameters
    for param in n.params
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end

# SPICE Temp: .temp val → temperature parameter
function (scope::CodeGenScope{<:AbstractSpectreSimulator})(n::SNode{SP.TempStatement})
    print(scope.io, "// .temp ")
    scope(n.temp)
    println(scope.io)
    println(scope.io, "// (Note: Convert to Spectre temperature setting)")
end
