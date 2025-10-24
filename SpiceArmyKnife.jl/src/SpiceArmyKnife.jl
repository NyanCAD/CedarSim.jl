module SpiceArmyKnife

using UUIDs
using Downloads
using p7zip_jll
using SpectreNetlistParser
using SpectreNetlistParser: SpectreNetlistCSTParser, SPICENetlistParser
using .SPICENetlistParser: SPICENetlistCSTParser
using .SpectreNetlistCSTParser: SpectreNetlistSource
using .SPICENetlistCSTParser: SPICENetlistSource
using SpectreNetlistParser.RedTree: fullcontents
using StringEncodings

const SNode = SpectreNetlistCSTParser.Node
const SC = SpectreNetlistCSTParser
const SP = SPICENetlistCSTParser

LSymbol(s) = Symbol(lowercase(String(s)))

# Include code generation
include("codegen.jl")

# Include parsing code
include("parse.jl")

# Code generation exports
export CodeGenScope, generate_code

# Include app submodules
include("Generate.jl")
include("Convert.jl")

end # module SpiceArmyKnife
