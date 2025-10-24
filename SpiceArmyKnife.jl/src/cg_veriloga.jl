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

# Verilog-A handler for SPICE Identifier - lowercase everything SPICE, add backtick for global `define references
function (scope::CodeGenScope{Sim})(n::SNode{SP.Identifier}) where {Sim <: AbstractVerilogASimulator}
    identifier_str = lowercase(String(n))
    identifier_sym = Symbol(identifier_str)

    if needs_backtick(scope, identifier_sym)
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

# Verilog-A handler for SPICE Model
# Context-aware: generates paramset at top-level, stores in local database when inside module
# Prefixes identifiers with 'model_' to avoid naming conflicts (SPICE allows model names starting with digits)
function (scope::CodeGenScope{Sim})(n::SNode{SP.Model}) where {Sim <: AbstractVerilogASimulator}
    model_name_orig = String(n.name)
    model_name = "model_" * lowercase(model_name_orig)
    device_type = String(n.typ)
    va_module = spice_device_type_to_va_module(device_type)

    # Look up VA model in database
    va_models = get(scope.options, :va_models, nothing)
    if va_models === nothing || isempty(va_models.models)
        error("VA model database not found in options - required for model generation")
    end

    va_model = get_model(va_models, va_module)
    if va_model === nothing
        error("VA model '$va_module' not found in database")
    end

    # Build override dictionary from modelcard parameters (lowercase keys for case-insensitive lookup)
    overrides = Dict{String, Any}()
    for param in n.parameters
        param_name_lower = lowercase(String(param.name))
        overrides[param_name_lower] = param.val
    end

    # Check scope: global generates paramset, nested stores locally
    if is_global_scope(scope)
        # TOP-LEVEL: Generate paramset
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

            # Only store parameters that have overrides
            if haskey(overrides, param_name_lower)
                value_str = render_to_string(scope, overrides[param_name_lower])
                push!(override_params, ModelParameter(param.name, param.ptype, value_str))
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

    # Parameter declarations from subcircuit header
    if !isempty(n.parameters)
        println(scope.io)
        for par in n.parameters
            param_name_str = lowercase(String(par.name))
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

# Verilog-A handler for SPICE Resistor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Resistor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = "node_" * String(n.pos)
    neg_node = "node_" * String(n.neg)

    # If params contains r or l, val is the model or nothing
    if hasparam(n.params, "r") || hasparam(n.params, "l")
        # val is model name (or nothing = built-in resistor)
        if n.val !== nothing
            # Has model reference - must be in local_db
            model_name_orig = String(n.val)
            local_db = get(scope.options, :local_models, nothing)
            local_model = local_db !== nothing ? get_model(local_db, model_name_orig) : nothing

            if local_model === nothing
                error("Resistor $inst_name references undefined model '$model_name_orig'")
            end

            # Local model found - inline parameters
            va_models = scope.options[:va_models]
            va_model = get_model(va_models, "resistor")

            # Start with model card's overrides
            param_dict = Dict{String, String}()
            for param in local_model.parameters
                param_dict[param.name] = param.default_value
            end

            # Override with instance parameters (looking up correct case from VA model)
            for param in n.params
                if param.val !== nothing
                    param_name_correct = get_param_name(va_model, String(param.name))
                    if param_name_correct !== nothing
                        param_dict[param_name_correct] = render_to_string(scope, param.val)
                    end
                end
            end

            # Generate instance with inlined parameters
            print(scope.io, "resistor #(")
            first_param = true
            for (name, value) in param_dict
                if !first_param
                    print(scope.io, ", ")
                end
                print(scope.io, ".", lowercase(name), "(", value, ")")
                first_param = false
            end
            print(scope.io, ") ", inst_name, " (", pos_node, ", ", neg_node, ");")
        else
            # No model - built-in resistor with parameters
            print(scope.io, "resistor #(")
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
        # val is the resistance value
        print(scope.io, "resistor #(.r(")
        if n.val !== nothing
            scope(n.val)
        end
        print(scope.io, ")) ", inst_name, " (", pos_node, ", ", neg_node, ");")
    end
    println(scope.io)
end

# Verilog-A handler for SPICE Capacitor
function (scope::CodeGenScope{Sim})(n::SNode{SP.Capacitor}) where {Sim <: AbstractVerilogASimulator}
    write_indent(scope)

    inst_name = String(n.name)
    pos_node = "node_" * String(n.pos)
    neg_node = "node_" * String(n.neg)

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
    pos_node = "node_" * String(n.pos)
    neg_node = "node_" * String(n.neg)

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

        # Start with model card's overrides
        param_dict = Dict{String, String}()
        for param in local_model.parameters
            param_dict[param.name] = param.default_value
        end

        # Override with instance parameters (looking up correct case from VA model)
        for param in n.params
            if param.val !== nothing
                # Get correct case from VA model
                param_name_correct = get_param_name(va_model, String(param.name))
                if param_name_correct !== nothing
                    param_dict[param_name_correct] = render_to_string(scope, param.val)
                end
            end
        end

        # Generate: va_module #(.param1(val1), ...) inst_name (pos, neg);
        print(scope.io, va_module)
        if !isempty(param_dict)
            print(scope.io, " #(")
            first_param = true
            for (param_name, param_value) in param_dict
                if !first_param
                    print(scope.io, ", ")
                end
                print(scope.io, ".", param_name, "(", param_value, ")")
                first_param = false
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

        # Start with model card's overrides
        param_dict = Dict{String, String}()
        for param in local_model.parameters
            param_dict[param.name] = param.default_value
        end

        # Override with instance parameters (looking up correct case from VA model)
        for param in n.parameters
            if param.val !== nothing
                # Get correct case from VA model
                param_name_correct = get_param_name(va_model, String(param.name))
                if param_name_correct !== nothing
                    param_dict[param_name_correct] = render_to_string(scope, param.val)
                end
            end
        end

        # Generate: va_module #(.param1(val1), ...) inst_name (nodes...);
        print(scope.io, va_module)
        if !isempty(param_dict)
            multiline = should_format_multiline(n.parameters)
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

                print(scope.io, ".", param_name, "(", param_value, ")")
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