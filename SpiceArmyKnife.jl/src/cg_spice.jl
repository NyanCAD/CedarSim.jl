# SPICE Code Generator
#
# SPICE-specific code generation methods for CodeGenScope{<:AbstractSpiceSimulator}
# This file contains all handlers that are specific to SPICE simulators
# (Ngspice, Hspice, Pspice, Xyce, etc.)

# =============================================================================
# SPICE Terminal Nodes
# =============================================================================

# Terminal handlers - only for SPICE to SPICE conversions
function (scope::CodeGenScope{Sim})(n::SNode{<:SP.Terminal}) where {Sim <: AbstractSpiceSimulator}
    print(scope.io, String(n))
end

# =============================================================================
# SPICE Node References
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

# =============================================================================
# SPICE Title and Braces
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
# SPICE Parameters
# =============================================================================

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
# SPICE Models
# =============================================================================

# SPICE Model handler with simulator-specific parameter conversion and filtering
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

        # Check if parameter name needs conversion (e.g., PSPICE � Ngspice)
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

# =============================================================================
# SPICE Subcircuits
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

    # Always output model in standard position (before parameters)
    scope(something(n.model, n.model_after))

    for param in n.parameters
        print(scope.io, " ")
        scope(param)
    end
    println(scope.io)
end
