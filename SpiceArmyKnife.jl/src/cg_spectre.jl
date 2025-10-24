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

    # End
    print(scope.io, "ends")
    if n.end_name !== nothing
        print(scope.io, " ")
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
