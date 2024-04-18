using AbstractTrees

const SC = SpectreNetlistCSTParser
const SP = SPICENetlistParser.SPICENetlistCSTParser

function visit_errors(sa; io=stdout, verbose=false)
    print("\n")
    for node in PreOrderDFS(sa)
        if node isa SC.Node{<:Union{SC.Error, SP.Error}}
            start = node.expr.off
            len = node.expr.width
            if node.parent isa SC.Node{<:Union{SC.Incomplete, SP.Incomplete}}
                context = node.parent
                start += context.expr.fullwidth - node.expr.fullwidth
            else
                context = node
            end
            lnn = LineNumberNode(context)
            printstyled(io, "ERROR: ", bold=true, color=:red)
            println(io, "unexpected token:")
            println(io, lnn.file, ":", lnn.line, ":")
            line = fullcontents(context)
            pointer = " "^start * "^"^len
            println(rstrip(line))
            printstyled(io, pointer, "\n"; color=:light_green)
            println(io, "got: $(node.expr.got)")
            if node.expr.expected !== nothing
                println(io, "expected: $(node.expr.expected)")
            end
        end
    end
end