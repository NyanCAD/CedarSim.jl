# =============================================================================
# Verilog-A Code Generation
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
    hasparam(params, name::String) -> Bool

Check if parameter list contains a parameter with the given name (case-insensitive).
"""
function hasparam(params, name::String)
    name_lower = lowercase(name)
    for p in params
        if lowercase(String(p.name)) == name_lower
            return true
        end
    end
    return false
end

"""
    spice_device_type_to_va_module(device_type::AbstractString, level=nothing, version=nothing; input_dialect=:ngspice) -> Tuple{String, Dict{Symbol, Any}}

Map SPICE device type codes to Verilog-A module names with level-dependent selection and configuration parameters.

Arguments:
- `device_type`: SPICE device type string (e.g., "NPN", "NMOS", "D", "R")
- `level`: Model level parameter (Integer or nothing)
- `version`: Model version parameter (String or nothing)
- `input_dialect`: Input simulator dialect (:ngspice or :xyce, default :ngspice)

Returns:
- Tuple `(name::String, params::Dict{Symbol, Any})` where:
  - `name`: Verilog-A module name
  - `params`: Dictionary of parameters needed to configure the model (e.g., `Dict(:type => 1)`)

Errors if device type or level combination is not supported.

Level-dependent mappings:

**BJT (NPN/PNP)**:
- Level 1 or nothing → "bjt" (Gummel-Poon) with :type parameter (1=NPN, -1=PNP)
- ngspice: Level 4, 9 → "vbic" with :type parameter
- Xyce: Level 11, 12 → "vbic" with :type parameter

**MOSFET (NMOS/PMOS)**:
- Level 14, 54 → "bsim4" with :TYPE parameter (1=NMOS, -1=PMOS)
- Level 17, 72 → "bsimcmg107" with :DEVTYPE parameter (1=NMOS, 0=PMOS)
- Level 8, 49 → "bsim3" with :TYPE parameter

**Simple devices** (R, C, L, D): Static mapping, empty parameter dict

Examples:
```julia
# BJT
spice_device_type_to_va_module("NPN")  # ("bjt", Dict(:type => 1))
spice_device_type_to_va_module("PNP", 9)  # ngspice level 9 → ("vbic", Dict(:type => -1))

# MOSFET
spice_device_type_to_va_module("NMOS", 14)  # ("bsim4", Dict(:TYPE => 1))
spice_device_type_to_va_module("PMOS", 17)  # ("bsimcmg107", Dict(:DEVTYPE => 0))

# Passive
spice_device_type_to_va_module("R")  # ("sp_resistor", Dict())
```
"""
function spice_device_type_to_va_module(device_type::AbstractString, level=nothing, version=nothing; input_dialect=:ngspice)
    device_upper = uppercase(strip(device_type))

    # BJT level-dependent mapping
    if device_upper in ("NPN", "PNP")
        type_value = device_upper == "NPN" ? 1 : -1
        params = Dict{Symbol, Any}(:type => type_value)

        if level === nothing || level == 1
            # Default Gummel-Poon model (bjt VA module)
            return ("sp_bjt", params)
        elseif input_dialect == :ngspice && level in (4, 9)
            # ngspice VBIC levels
            return ("vbic_4T_et_cf", params)
        elseif input_dialect == :xyce && level in (11, 12)
            # Xyce VBIC levels
            return ("vbic_4T_et_cf", params)
        else
            error("Unsupported BJT level $level for input dialect $input_dialect")
        end
    end

    # MOSFET level-dependent mapping
    if device_upper in ("NMOS", "PMOS")
        is_nmos = device_upper == "NMOS"

        if level === nothing
            error("MOSFET model without level specification - cannot determine model type")
        elseif level in (14, 54)
            # BSIM4 - uses TYPE parameter
            params = Dict{Symbol, Any}(:TYPE => (is_nmos ? 1 : -1))
            return ("bsim4", params)
        elseif level in (17, 72)
            # BSIMCMG - uses DEVTYPE parameter with different convention
            if version === nothing || version == "107"
                params = Dict{Symbol, Any}(:DEVTYPE => (is_nmos ? 1 : 0))
                return ("bsimcmg107", params)
            else
                error("Unsupported BSIMCMG version $version (only 107 supported)")
            end
        elseif level in (8, 49)
            # BSIM3 - uses TYPE parameter
            params = Dict{Symbol, Any}(:TYPE => (is_nmos ? 1 : -1))
            return ("bsim3", params)
        else
            error("Unsupported MOSFET level $level")
        end
    end

    # Static mappings for simple devices (no level dependency, no type parameters)
    static_mapping = Dict(
        "D" => "sp_diode",
        "R" => "sp_resistor",
        "C" => "sp_capacitor",
        "L" => "sp_inductor",
        "PSP103_VA" => "PSPNQS103VA",
    )

    if haskey(static_mapping, device_upper)
        return (static_mapping[device_upper], Dict{Symbol, Any}())
    end

    # Fallback: use device type as module name with no type parameters
    return (device_upper, Dict{Symbol, Any}())
end

# =============================================================================
# Verilog-A Handlers - Convert SPICE/Spectre to Verilog-A
# =============================================================================

# Verilog-A terminal handlers - explicit support for common terminals
function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.Operator, SC.Operator}}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, String(n))
end

function (scope::CodeGenScope{Sim})(n::SNode{<:Union{SP.StringLiteral, SC.StringLiteral}}) where {Sim <: AbstractVerilogASimulator}
    print(scope.io, String(n))
end

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

# Verilog-A handler for SPICE End statement - skip it (Verilog-A doesn't use .end)
function (scope::CodeGenScope{Sim})(n::SNode{SP.EndStatement}) where {Sim <: AbstractVerilogASimulator}
    # No-op: Verilog-A doesn't have .end statements, skip them
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
# All SPICE parameter names are lowercased
function (scope::CodeGenScope{Sim})(n::SNode{SP.ParamStatement}) where {Sim <: AbstractVerilogASimulator}
    for param in n.params
        param_name_str = lowercase(String(param.name))
        param_name_sym = Symbol(param_name_str)

        # Track parameter in current scope
        add_param(scope, param_name_sym)

        # Warn if parameter has no value (unusual in .param statements)
        if param.val === nothing
            @warn "Parameter '$param_name_str' has no value in .param statement - defaulting to 0" maxlog=1
        end

        if is_global_scope(scope)
            # Top-level: emit `define macro
            print(scope.io, "`define ", param_name_str, " ")
            scope(param.val === nothing ? "0" : param.val)
            println(scope.io)
        else
            # Module-level: emit parameter declaration
            write_indent(scope)
            print(scope.io, "parameter real ", param_name_str, " = ")
            scope(param.val === nothing ? "0" : param.val)
            println(scope.io, ";")
        end
    end
end

# Verilog-A handler for SPICE Identifier - lowercase everything SPICE, add backtick for global `define references
function (scope::CodeGenScope{Sim})(n::SNode{SP.Identifier}) where {Sim <: AbstractVerilogASimulator}
    identifier_str = lowercase(String(n))
    identifier_sym = Symbol(identifier_str)

    # Special handling for SPICE temperature variable
    if identifier_str == "temper"
        # Convert SPICE temper (Celsius) to Verilog-A $temperature (Kelvin) with unit conversion
        print(scope.io, "(\$temperature - 273.15)")
    elseif needs_backtick(scope, identifier_sym)
        # Global parameter - needs backtick prefix
        print(scope.io, "`", identifier_str)
    else
        # Regular identifier
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

# Verilog-A handler for SPICE FunctionCall
function (scope::CodeGenScope{Sim})(n::SNode{SP.FunctionCall}) where {Sim <: AbstractVerilogASimulator}
    func_name = lowercase(String(n.id))

    if func_name == "gauss"
        # GAUSS(μ, α, n) - Gaussian variation with relative std dev
        # Returns: N(μ, (α*μ)/n) - a random number from normal distribution
        #
        # Xyce: GAUSS(μ, α, n=1.1) → N(μ, (α*μ)/n)
        # ngspice: gauss(nom, rvar, sigma) → nom + (nom*rvar/sigma)*N(0,1)
        #          with defaults v=1.0, w=0.0 for missing args
        #          Special case: if rvar <= 0 || sigma <= 0, return nom

        input_dialect = get(scope.options, :spice_dialect, :ngspice)
        nargs = length(n.args)

        # Parse arguments based on dialect (assign defaults directly)
        local mu_arg, var_arg, n_arg
        if input_dialect == :xyce
            # Xyce: GAUSS(μ, α, n=1)
            if nargs < 2 || nargs > 3
                error("Xyce GAUSS() requires 2-3 arguments: μ, α, [n=1]")
            end
            mu_arg = n.args[1].item
            var_arg = n.args[2].item
            n_arg = nargs == 3 ? n.args[3].item : 1
        else
            # ngspice: gauss(nom, rvar, sigma)
            if nargs < 1 || nargs > 3
                error("ngspice gauss() requires 1-3 arguments: [nom=1.0, [rvar=0.0,]] sigma")
            end
            if nargs == 1
                mu_arg = 1.0
                var_arg = 0.0
                n_arg = n.args[1].item
            elseif nargs == 2
                mu_arg = n.args[1].item
                var_arg = 0.0
                n_arg = n.args[2].item
            else
                mu_arg = n.args[1].item
                var_arg = n.args[2].item
                n_arg = n.args[3].item
            end
        end

        # Generate: (var <= 0 || n <= 0) ? μ : $rdist_normal(_rdist_seed, μ, (var*μ)/n)
        print(scope.io, "((")
        scope(var_arg)
        print(scope.io, " <= 0) || (")
        scope(n_arg)
        print(scope.io, " <= 0) ? ")
        scope(mu_arg)
        print(scope.io, " : \$rdist_normal(_rdist_seed, ")
        scope(mu_arg)
        print(scope.io, ", (")
        scope(var_arg)
        print(scope.io, " * ")
        scope(mu_arg)
        print(scope.io, ") / ")
        scope(n_arg)
        print(scope.io, "))")

    elseif func_name == "agauss"
        # AGAUSS(μ, α, n) - Gaussian variation with absolute std dev
        # Returns: N(μ, α/n) - a random number from normal distribution
        #
        # Xyce: AGAUSS(μ, α, n=1) → N(μ, α/n)
        # ngspice: agauss(nom, avar, sigma) → nom + (avar/sigma)*N(0,1)
        #          with defaults v=1.0, w=0.0 for missing args
        #          Special case: if avar <= 0 || sigma <= 0, return nom

        input_dialect = get(scope.options, :spice_dialect, :ngspice)
        nargs = length(n.args)

        # Parse arguments based on dialect (assign defaults directly)
        local mu_arg, var_arg, n_arg
        if input_dialect == :xyce
            # Xyce: AGAUSS(μ, α, n=1)
            if nargs < 2 || nargs > 3
                error("Xyce AGAUSS() requires 2-3 arguments: μ, α, [n=1]")
            end
            mu_arg = n.args[1].item
            var_arg = n.args[2].item
            n_arg = nargs == 3 ? n.args[3].item : 1
        else
            # ngspice: agauss(nom, avar, sigma)
            if nargs < 1 || nargs > 3
                error("ngspice agauss() requires 1-3 arguments: [nom=1.0, [avar=0.0,]] sigma")
            end
            if nargs == 1
                mu_arg = 1.0
                var_arg = 0.0
                n_arg = n.args[1].item
            elseif nargs == 2
                mu_arg = n.args[1].item
                var_arg = 0.0
                n_arg = n.args[2].item
            else
                mu_arg = n.args[1].item
                var_arg = n.args[2].item
                n_arg = n.args[3].item
            end
        end

        # Generate: (var <= 0 || n <= 0) ? μ : $rdist_normal(_rdist_seed, μ, var/n)
        print(scope.io, "((")
        scope(var_arg)
        print(scope.io, " <= 0) || (")
        scope(n_arg)
        print(scope.io, " <= 0) ? ")
        scope(mu_arg)
        print(scope.io, " : \$rdist_normal(_rdist_seed, ")
        scope(mu_arg)
        print(scope.io, ", ")
        scope(var_arg)
        print(scope.io, " / ")
        scope(n_arg)
        print(scope.io, "))")

    else
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
end

# Verilog-A handler for SPICE Model
# Context-aware: generates paramset at top-level, stores in local database when inside module
# Prefixes identifiers with 'model_' to avoid naming conflicts (SPICE allows model names starting with digits)
function (scope::CodeGenScope{Sim})(n::SNode{SP.Model}) where {Sim <: AbstractVerilogASimulator}
    model_name_orig = String(n.name)
    model_name = "model_" * lowercase(model_name_orig)
    device_type = String(n.typ)

    # Build override dictionary from modelcard parameters (lowercase keys for case-insensitive lookup)
    overrides = Dict{String, Any}()
    for param in n.parameters
        param_name_lower = lowercase(String(param.name))
        overrides[param_name_lower] = param.val
    end

    # Extract level and version for model selection
    level = haskey(overrides, "level") ? parse(Int, String(overrides["level"])) : nothing
    version = haskey(overrides, "version") ? String(overrides["version"]) : nothing

    # Get input dialect from options (default to ngspice)
    input_dialect = get(scope.options, :spice_dialect, :ngspice)

    # Map device type to VA module with level-dependent selection (errors if unsupported)
    va_module, type_params = spice_device_type_to_va_module(device_type, level, version; input_dialect=input_dialect)

    # Merge type parameters into overrides dict (these configure polarity/type)
    for (param_name, param_value) in type_params
        param_name_lower = lowercase(String(param_name))
        overrides[param_name_lower] = string(param_value)  # Raw value, not AST node
    end

    # Look up VA model in database
    va_models = get(scope.options, :va_models, nothing)
    if va_models === nothing || isempty(va_models.models)
        error("VA model database not found in options - required for model generation")
    end

    va_model = get_model(va_models, va_module)
    if va_model === nothing
        error("VA model '$va_module' not found in database")
    end

    # Check scope: global generates paramset, nested stores locally
    if is_global_scope(scope)
        # TOP-LEVEL: Generate paramset

        # Emit `include for VA module source file if not already included
        if va_model.source_file !== nothing
            included = get!(scope.options, :included_va_files) do
                Set{String}()
            end

            if !(va_model.source_file in included)
                println(scope.io, "`include \"", va_model.source_file, "\"")
                push!(included, va_model.source_file)
            end
        end

        println(scope.io, "paramset ", model_name, " ", va_module, ";")

        # Generate parameter declarations (use lowercase)
        for param in va_model.parameters
            param_name_lower = lowercase(param.name)

            print(scope.io, "  parameter ", param.ptype, " ", param_name_lower, " = ")
            if haskey(overrides, param_name_lower)
                # Use override value from modelcard
                scope(overrides[param_name_lower])
            else
                # Use default value from VA model
                print(scope.io, param.default_value)
            end
            println(scope.io, ";")
        end

        # Generate parameter assignments (VA model case = lowercase)
        for param in va_model.parameters
            param_name_lower = lowercase(param.name)
            println(scope.io, "  .", param.name, " = ", param_name_lower, ";")
        end

        # End paramset
        println(scope.io, "endparamset")
        println(scope.io)  # Extra blank line after paramset
    else
        # INSIDE MODULE: Store in local ModelDatabase, don't generate code

        # Get or create local models database
        local_db = get!(scope.options, :local_models) do
            ModelDatabase(ModelDefinition[])
        end

        # Build parameter list with only overrides (not defaults)
        override_params = ModelParameter[]
        for param in va_model.parameters
            param_name_lower = lowercase(param.name)

            # Only store parameters that have overrides (store AST node directly)
            if haskey(overrides, param_name_lower)
                push!(override_params, ModelParameter(param.name, param.ptype, overrides[param_name_lower]))
            end
        end

        # Create model definition (name is just va_module)
        model_def = ModelDefinition(va_module, override_params)

        # Add to database (mutates in place)
        add_model!(local_db, model_def, model_name)
    end
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

    # Collect port names (prefix all with node_)
    port_names = String[]
    for node in n.subckt_nodes
        push!(port_names, "node_" * String(node))
    end

    print(scope.io, join(port_names, ", "))
    println(scope.io, ");")

    # Port direction declarations: inout port1, port2, ...;
    print(scope.io, "  inout ")
    println(scope.io, join(port_names, ", "), ";")

    # Electrical discipline declarations: electrical port1, port2, ...;
    print(scope.io, "  electrical ")
    println(scope.io, join(port_names, ", "), ";")

    println(scope.io)

    # Always add _rdist_seed parameter for $rdist_normal support
    println(scope.io, "  parameter integer _rdist_seed = 0;")

    # Parameter declarations from subcircuit header
    if !isempty(n.parameters)
        for par in n.parameters
            param_name_str = lowercase(String(par.name))

            # Warn if subcircuit parameter has no default value
            if par.val === nothing
                @warn "Subcircuit parameter '$param_name_str' has no default value - defaulting to 0" maxlog=1
            end

            print(scope.io, "  parameter real ", param_name_str, " = ")
            child_scope(par.val === nothing ? "0" : par.val)
            println(scope.io, ";")
        end
    end

    println(scope.io)

    # Body statements (with child scope and increased indent)
    inner_scope = with_indent(child_scope, 1)

    # First pass: process .model cards to populate local_db
    for stmt in n.stmts
        if stmt isa SNode{SP.Model}
            inner_scope(stmt)
        end
    end

    # Second pass: process all non-model statements
    for stmt in n.stmts
        if !(stmt isa SNode{SP.Model})
            inner_scope(stmt)
        end
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

"""
    spice_two_terminal_device(scope, n, device_type, param_checks, default_param)

Generate Verilog-A code for two-terminal SPICE devices (resistor, capacitor, inductor).
Handles three cases:
1. Model reference with parameters - inlines model + instance params
2. Built-in device with explicit parameters - no model reference
3. Simple value form - single parameter value

# Arguments
- `scope`: CodeGenScope for code generation
- `n`: AST node (SP.Resistor, SP.Capacitor, etc.)
- `device_type`: VA module name ("resistor", "capacitor", "inductor")
- `param_checks`: List of parameter names that indicate param-based syntax
- `default_param`: Parameter name for simple value case ("r", "c", "l")
"""
function spice_two_terminal_device(scope::CodeGenScope, n, device_type::String, param_checks::Vector{String}, default_param::String)
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = "node_" * String(n.pos)
    neg_node = "node_" * String(n.neg)

    # Check if params contains any of the specified parameter names
    has_params = any(param_name -> hasparam(n.params, param_name), param_checks)

    if has_params
        # val is model name (or nothing = built-in device)
        if n.val !== nothing
            # Has model reference - check if it's local or global
            model_name_orig = String(n.val)
            local_db = get(scope.options, :local_models, nothing)
            local_model = local_db !== nothing ? get_model(local_db, model_name_orig) : nothing

            if local_model !== nothing
                # INLINE: Local model found - inline parameters
                va_models = scope.options[:va_models]
                va_model = get_model(va_models, device_type)

                # Start with model card's overrides (store AST nodes, not strings)
                param_dict = Dict{String, Union{String, SNode}}()
                for param in local_model.parameters
                    param_dict[param.name] = param.default_value
                end

                # Override with instance parameters (store AST nodes directly)
                for param in n.params
                    if param.val !== nothing
                        param_name_correct = get_param_name(va_model, String(param.name))
                        if param_name_correct !== nothing
                            param_dict[param_name_correct] = param.val
                        end
                    end
                end

                # Generate instance with inlined parameters
                multiline = should_format_multiline(param_dict)
                print(scope.io, device_type, " #(")

                first_param = true
                for (name, value) in param_dict
                    if !first_param
                        print(scope.io, ",")
                    end

                    if multiline
                        println(scope.io)
                        write_indent(scope)
                        print(scope.io, "  ")
                    else
                        if !first_param
                            print(scope.io, " ")
                        end
                    end

                    print(scope.io, ".", lowercase(name), "(")
                    scope(value)  # Handles both String and SNode
                    print(scope.io, ")")
                    first_param = false
                end

                if multiline
                    println(scope.io)
                    write_indent(scope)
                end
                print(scope.io, ") ", inst_name, " (", pos_node, ", ", neg_node, ");")
            else
                # REFERENCE: Model defined at top-level, use paramset reference
                model_name = "model_" * lowercase(model_name_orig)

                # model_<name> #(.param1(val1), ...) <name> (<pos>, <neg>);
                print(scope.io, model_name)

                # Add instance parameters if present
                if !isempty(n.params)
                    print(scope.io, " #(")
                    first_param = true
                    for param in n.params
                        if !first_param
                            print(scope.io, ", ")
                        end
                        param_name = lowercase(String(param.name))
                        print(scope.io, ".", param_name, "(")

                        if param.val !== nothing
                            scope(param.val)
                        end

                        print(scope.io, ")")
                        first_param = false
                    end
                    print(scope.io, ")")
                end

                print(scope.io, " ", inst_name, " (", pos_node, ", ", neg_node, ");")
            end
        else
            # No model - built-in device with parameters
            print(scope.io, device_type, " #(")
            first_param = true
            for param in n.params
                if !first_param
                    print(scope.io, ", ")
                end
                print(scope.io, ".", lowercase(String(param.name)), "(")
                if param.val !== nothing
                    scope(param.val)
                end
                print(scope.io, ")")
                first_param = false
            end
            print(scope.io, ") ", inst_name, " (", pos_node, ", ", neg_node, ");")
        end
    else
        # val is the parameter value
        print(scope.io, device_type, " #(.", default_param, "(")
        if n.val !== nothing
            scope(n.val)
        end
        print(scope.io, ")) ", inst_name, " (", pos_node, ", ", neg_node, ");")
    end
    println(scope.io)
end

# Verilog-A handler for SPICE Resistor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Resistor}) where {Sim <: AbstractVerilogASimulator}
    spice_two_terminal_device(scope, n, "sp_resistor", ["r", "l"], "r")
end

# Verilog-A handler for SPICE Capacitor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Capacitor}) where {Sim <: AbstractVerilogASimulator}
    spice_two_terminal_device(scope, n, "sp_capacitor", ["c", "l", "w"], "c")
end

# Verilog-A handler for SPICE Inductor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Inductor}) where {Sim <: AbstractVerilogASimulator}
    spice_two_terminal_device(scope, n, "sp_inductor", ["l"], "l")
end

# Verilog-A handler for SPICE Diode
function (scope::CodeGenScope{Sim})(n::SNode{SP.Diode}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = "node_" * String(n.pos)
    neg_node = "node_" * String(n.neg)
    model_name_orig = String(n.model)
    model_name = "model_" * lowercase(model_name_orig)

    # Check if model is defined locally (inside module)
    local_db = get(scope.options, :local_models, nothing)
    local_model = local_db !== nothing ? get_model(local_db, model_name) : nothing

    if local_model !== nothing
        # INLINE: Model defined locally, merge parameters directly

        # va_module is stored directly in ModelDefinition.name
        va_module = local_model.name

        # Get full VA model for case-correct parameter lookup
        va_models = scope.options[:va_models]
        va_model = get_model(va_models, va_module)

        # Start with model card's overrides (store AST nodes, not strings)
        param_dict = Dict{String, Union{String, SNode}}()
        for param in local_model.parameters
            param_dict[param.name] = param.default_value
        end

        # Override with instance parameters (store AST nodes directly)
        for param in n.params
            if param.val !== nothing
                # Get correct case from VA model
                param_name_correct = get_param_name(va_model, String(param.name))
                if param_name_correct !== nothing
                    param_dict[param_name_correct] = param.val
                end
            end
        end

        # Generate: va_module #(.param1(val1), ...) inst_name (pos, neg);
        print(scope.io, va_module)
        if !isempty(param_dict)
            multiline = should_format_multiline(param_dict)
            print(scope.io, " #(")

            first_param = true
            for (param_name, param_value) in param_dict
                if !first_param
                    print(scope.io, ",")
                end

                if multiline
                    println(scope.io)
                    write_indent(scope)
                    print(scope.io, "  ")
                else
                    if !first_param
                        print(scope.io, " ")
                    end
                end

                print(scope.io, ".", param_name, "(")
                scope(param_value)  # Handles both String and SNode
                print(scope.io, ")")
                first_param = false
            end

            if multiline
                println(scope.io)
                write_indent(scope)
            end
            print(scope.io, ")")
        end
        print(scope.io, " ", inst_name, " (", pos_node, ", ", neg_node, ");")
    else
        # REFERENCE: Model defined at top-level, use paramset reference

        # model_<name> #(.param1(val1), ...) <name> (<pos>, <neg>);
        print(scope.io, model_name)

        # Add instance parameters if present
        if !isempty(n.params)
            print(scope.io, " #(")
            first_param = true
            for param in n.params
                if !first_param
                    print(scope.io, ", ")
                end
                param_name = lowercase(String(param.name))
                print(scope.io, ".", param_name, "(")

                if param.val !== nothing
                    scope(param.val)
                end

                print(scope.io, ")")
                first_param = false
            end
            print(scope.io, ")")
        end

        print(scope.io, " ", inst_name, " (", pos_node, ", ", neg_node, ");")
    end

    println(scope.io)
end

# Verilog-A handler for SPICE Bipolar Transistor (BJT)
function (scope::CodeGenScope{Sim})(n::SNode{SP.BipolarTransistor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    collector_node = "node_" * String(n.c)
    base_node = "node_" * String(n.b)
    emitter_node = "node_" * String(n.e)
    substrate_node = n.s !== nothing ? "node_" * String(n.s) : nothing
    temp_node = n.t !== nothing ? "node_" * String(n.t) : nothing

    model_name_orig = String(n.model)
    model_name = "model_" * lowercase(model_name_orig)

    # Check if model is defined locally (inside module)
    local_db = get(scope.options, :local_models, nothing)
    local_model = local_db !== nothing ? get_model(local_db, model_name) : nothing

    if local_model !== nothing
        # INLINE: Model defined locally, merge parameters directly

        # va_module is stored directly in ModelDefinition.name
        va_module = local_model.name

        # Get full VA model for case-correct parameter lookup
        va_models = scope.options[:va_models]
        va_model = get_model(va_models, va_module)

        # Start with model card's overrides (store AST nodes, not strings)
        param_dict = Dict{String, Union{String, SNode}}()
        for param in local_model.parameters
            param_dict[param.name] = param.default_value
        end

        # Override with instance parameters (store AST nodes directly)
        for param in n.params
            if param.val !== nothing
                # Get correct case from VA model
                param_name_correct = get_param_name(va_model, String(param.name))
                if param_name_correct !== nothing
                    param_dict[param_name_correct] = param.val
                end
            end
        end

        # Generate: va_module #(.param1(val1), ...) inst_name (c, b, e[, s][, t]);
        print(scope.io, va_module)
        if !isempty(param_dict)
            multiline = should_format_multiline(param_dict)
            print(scope.io, " #(")

            first_param = true
            for (param_name, param_value) in param_dict
                if !first_param
                    print(scope.io, ",")
                end

                if multiline
                    println(scope.io)
                    write_indent(scope)
                    print(scope.io, "  ")
                else
                    if !first_param
                        print(scope.io, " ")
                    end
                end

                print(scope.io, ".", param_name, "(")
                scope(param_value)  # Handles both String and SNode
                print(scope.io, ")")
                first_param = false
            end

            if multiline
                println(scope.io)
                write_indent(scope)
            end
            print(scope.io, ")")
        end

        # Print nodes (c, b, e, and optional s, t)
        print(scope.io, " ", inst_name, " (", collector_node, ", ", base_node, ", ", emitter_node)
        if substrate_node !== nothing
            print(scope.io, ", ", substrate_node)
        end
        if temp_node !== nothing
            print(scope.io, ", ", temp_node)
        end
        print(scope.io, ");")
    else
        # REFERENCE: Model defined at top-level, use paramset reference

        # model_<name> #(.param1(val1), ...) <name> (c, b, e[, s][, t]);
        print(scope.io, model_name)

        # Add instance parameters if present
        if !isempty(n.params)
            multiline = should_format_multiline(n.params)
            print(scope.io, " #(")

            first_param = true
            for param in n.params
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

                param_name = lowercase(String(param.name))
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

        # Print nodes (c, b, e, and optional s, t)
        print(scope.io, " ", inst_name, " (", collector_node, ", ", base_node, ", ", emitter_node)
        if substrate_node !== nothing
            print(scope.io, ", ", substrate_node)
        end
        if temp_node !== nothing
            print(scope.io, ", ", temp_node)
        end
        print(scope.io, ");")
    end

    println(scope.io)
end

# Verilog-A handler for SPICE OSDI Device (N prefix - OpenVAF/OSDI models, Y prefix - Xyce ADMS models)
# Uses paramset calling convention with variable nodes like SubcktCall
function (scope::CodeGenScope{Sim})(n::SNode{SP.OSDIDevice}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    model_name_orig = String(n.model)
    model_name = "model_" * lowercase(model_name_orig)

    # Collect node names (without prefix yet)
    node_names = String[]
    for node in n.nodes
        push!(node_names, String(node))
    end

    if startswith(lowercase(inst_name), "y")
        # Xyce OSDI device:
        # Y<module name> <unique instance name>  <node>* <model name> <instance parameter list>
        # First "node" is actually the instance name
        inst_name = popfirst!(node_names)
    end

    # Check if model is defined locally (inside module)
    local_db = get(scope.options, :local_models, nothing)
    local_model = local_db !== nothing ? get_model(local_db, model_name) : nothing

    if local_model !== nothing
        # INLINE: Model defined locally, merge parameters directly

        # va_module is stored directly in ModelDefinition.name
        va_module = local_model.name

        # Get full VA model for case-correct parameter lookup
        va_models = scope.options[:va_models]
        va_model = get_model(va_models, va_module)

        # Start with model card's overrides (store AST nodes, not strings)
        param_dict = Dict{String, Union{String, SNode}}()
        for param in local_model.parameters
            param_dict[param.name] = param.default_value
        end

        # Override with instance parameters (store AST nodes directly)
        for param in n.parameters
            if param.val !== nothing
                # Get correct case from VA model
                param_name_correct = get_param_name(va_model, String(param.name))
                if param_name_correct !== nothing
                    param_dict[param_name_correct] = param.val
                end
            end
        end

        # Generate: va_module #(.param1(val1), ...) inst_name (nodes...);
        print(scope.io, va_module)
        if !isempty(param_dict)
            multiline = should_format_multiline(param_dict)
            print(scope.io, " #(")

            first_param = true
            for (param_name, param_value) in param_dict
                if !first_param
                    print(scope.io, ",")
                end

                if multiline
                    println(scope.io)
                    write_indent(scope)
                    print(scope.io, "  ")
                else
                    if !first_param
                        print(scope.io, " ")
                    end
                end

                print(scope.io, ".", param_name, "(")
                scope(param_value)  # Handles both String and SNode
                print(scope.io, ")")
                first_param = false
            end

            if multiline
                println(scope.io)
                write_indent(scope)
            end
            print(scope.io, ")")
        end
        print(scope.io, " ", inst_name, " (", join("node_" .* node_names, ", "), ");")
    else
        # REFERENCE: Model defined at top-level, use paramset reference

        # model_<name> #(.param1(val1), ...) <name> (nodes...);
        print(scope.io, model_name)

        # Add instance parameters if present
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

                param_name = lowercase(String(param.name))
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

        print(scope.io, " ", inst_name, " (", join("node_" .* node_names, ", "), ");")
    end

    println(scope.io)
end

# Verilog-A handler for SPICE Subcircuit Call
function (scope::CodeGenScope{Sim})(n::SNode{SP.SubcktCall}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    subckt_name = String(n.model)

    # Collect node names (without prefix yet)
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

            param_name = lowercase(String(param.name))
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
    print(scope.io, join("node_" .* node_names, ", "))
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