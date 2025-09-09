module SpiceArmyKnife

using UUIDs
using Downloads
using p7zip_jll
using SpectreNetlistParser
using SpectreNetlistParser: SpectreNetlistCSTParser, SPICENetlistParser
using .SPICENetlistParser: SPICENetlistCSTParser
using .SpectreNetlistCSTParser: SpectreNetlistSource
using .SPICENetlistCSTParser: SPICENetlistSource

const SNode = SpectreNetlistCSTParser.Node
const SC = SpectreNetlistCSTParser
const SP = SPICENetlistCSTParser

LSymbol(s) = Symbol(lowercase(String(s)))

"""
    ExtractionConfig

Configuration for extracting definitions from SPICE/Spectre AST.
"""
mutable struct ExtractionConfig
    models::Vector{Any}
    subcircuits::Vector{Any}
    parsed_files::Dict{String, Any}
    includepaths::Vector{String}
    libraries::Set{Tuple{String,String}}
    depth::Int
    lib_section::Union{String, Nothing}
    max_depth::Int
    current_file::String
    
    function ExtractionConfig(; models=[], subcircuits=[], parsed_files=Dict{String, Any}(), 
                            includepaths=String[], libraries=Set{Tuple{String,String}}(), 
                            depth=0, lib_section=nothing, max_depth=10, current_file="")
        new(models, subcircuits, parsed_files, includepaths, libraries, depth, lib_section, max_depth, current_file)
    end
end

# Helper function to create a new config with incremented depth
function deeper(config::ExtractionConfig; new_includepaths=nothing, new_file=nothing)
    ExtractionConfig(
        models=config.models, subcircuits=config.subcircuits, 
        parsed_files=config.parsed_files, 
        includepaths=new_includepaths === nothing ? config.includepaths : new_includepaths,
        libraries=config.libraries, depth=config.depth+1, 
        lib_section=config.lib_section, max_depth=config.max_depth,
        current_file=new_file === nothing ? config.current_file : new_file)
end

"""
    ArchiveConfig

Configuration for processing an archive with SPICE/Spectre models.

Fields:
- url: URL to download archive from
- entrypoints: Either Vector{String} of specific paths or nothing for auto-discovery
- base_category: Base category path for Mosaic format
- mode: Template mode (:inline, :include, :lib)
- lib_section: If specified, only process this .lib section to avoid duplicates
- max_depth: Maximum recursion depth to avoid implementation details
"""
struct ArchiveConfig
    url::String
    entrypoints::Union{Vector{String}, Nothing}
    base_category::Vector{String}
    mode::Symbol
    lib_section::Union{String, Nothing}
    max_depth::Int
    
    function ArchiveConfig(url, entrypoints, base_category, mode; lib_section=nothing, max_depth=10)
        new(url, entrypoints, base_category, mode, lib_section, max_depth)
    end
end

"""
    generate_template_code(code, mode, archive_url, file_path)

Generate template code for Mosaic format.
- mode = :inline: returns the actual code  
- mode = :include: returns .include statement
- mode = :lib: returns .lib statement with {corner} section
"""
function generate_template_code(code, mode, archive_url, file_path)
    if mode == :inline
        return code
    elseif mode == :include
        path = archive_url !== nothing ? "\"$(archive_url)#$(file_path)\"" : file_path
        return ".include $(path)"
    elseif mode == :lib
        path = archive_url !== nothing ? "\"$(archive_url)#$(file_path)\"" : file_path
        return ".lib $(path) {corner}"
    else
        error("Invalid mode: $mode. Must be :inline, :include, or :lib")
    end
end

"""
    extract_definitions_from_file(filepath::String; lib_section=nothing, max_depth=10) -> (models, subcircuits)

Parse a SPICE/Spectre file and extract model and subcircuit definitions.
Uses automatic file extension detection (.scs = Spectre, others = SPICE).
Handles .include and .lib statements by recursively parsing referenced files.
"""
function extract_definitions_from_file(filepath::String; lib_section=nothing, max_depth=10)
    ast = SpectreNetlistParser.parsefile(filepath; implicit_title=false)
    config = ExtractionConfig(
        includepaths=[dirname(abspath(filepath))],
        lib_section=lib_section,
        max_depth=max_depth,
        current_file=filepath
    )
    
    extract_definitions(ast, config)
    return config.models, config.subcircuits
end

"""
    extract_definitions(ast, config::ExtractionConfig)

Extract model and subcircuit definitions from a SPICE/Spectre AST using the provided configuration.
Returns models as (name, type, subtype, code) tuples and subcircuits as (name, ports, parameters, code) tuples.
For models, subtype indicates polarity (:pmos/:nmos), defaults to :nmos unless 'pchan' or 'pmos' found in parameters.
For subcircuits, parameters is a list of parameter names from both subckt line and .param statements inside.
Code is the full source text extracted using String(node).
"""
function extract_definitions(ast, config::ExtractionConfig)
    # Check recursion depth limit
    if config.depth > config.max_depth
        file_info = config.current_file == "" ? "" : " in $(basename(config.current_file))"
        println("Warning: Max depth ($(config.max_depth)) reached$file_info, stopping recursion")
        return config.models, config.subcircuits
    end
    for stmt in ast.stmts
        if isa(stmt, SNode{SPICENetlistSource})
            # Recurse into netlist source nodes
            extract_definitions(stmt, config)
        elseif isa(stmt, SNode{SpectreNetlistSource})
            # Recurse into spectre netlist source nodes
            extract_definitions(stmt, config)
        elseif isa(stmt, SNode{SP.LibStatement})
            # Recurse into .lib sections, but filter by lib_section if specified
            section_name = String(stmt.name)
            if config.lib_section === nothing || section_name == config.lib_section
                extract_definitions(stmt, deeper(config))
            end
        elseif isa(stmt, SNode{SP.IncludeStatement})
            # Handle .include statements
            str = strip(String(stmt.path), ['"', '\''])
            try
                _, path = resolve_includepath(str, config.includepaths)
                sa = get!(() -> SpectreNetlistParser.parsefile(path; implicit_title=false), config.parsed_files, path)
                new_includepaths = [dirname(path), config.includepaths...]
                extract_definitions(sa, deeper(config; new_includepaths, new_file=path))
            catch e
                println("Warning: Could not process include $str: $e")
            end
        elseif isa(stmt, SNode{SP.LibInclude})
            # Handle .lib statements (includes with section)
            str = strip(String(stmt.path), ['"', '\''])
            section = String(stmt.name)
            try
                _, path = resolve_includepath(str, config.includepaths)
                lib_key = (path, section)
                if lib_key ∉ config.libraries
                    push!(config.libraries, lib_key)
                    p = get!(() -> SpectreNetlistParser.parsefile(path; implicit_title=false), config.parsed_files, path)
                    sa = extract_section_from_lib(p; section)
                    if sa !== nothing
                        new_includepaths = [dirname(path), config.includepaths...]
                        extract_definitions(sa, deeper(config; new_includepaths, new_file=path))
                    else
                        println("Warning: Unable to find section '$section' in $str")
                    end
                end
            catch e
                println("Warning: Could not process lib include $str section $section: $e")
            end
        elseif isa(stmt, SNode{SP.Model})
            name = LSymbol(stmt.name)
            typ = LSymbol(stmt.typ)
            # Check for PMOS indicators in parameters
            params = [LSymbol(p.name) for p in stmt.parameters]
            subtype = (:pchan in params || :pmos in params) ? :pmos : :nmos
            code = String(stmt)
            push!(config.models, (name, typ, subtype, code))
        elseif isa(stmt, SNode{SC.Model})
            name = LSymbol(stmt.name)
            typ = LSymbol(stmt.master_name)
            # Check for PMOS indicators in parameters
            params = [LSymbol(p.name) for p in stmt.parameters]
            subtype = (:pchan in params || :pmos in params) ? :pmos : :nmos
            code = String(stmt)
            push!(config.models, (name, typ, subtype, code))
        elseif isa(stmt, SNode{SP.Subckt})
            name = LSymbol(stmt.name)
            ports = [LSymbol(node.name) for node in stmt.subckt_nodes]
            # Start with parameters from subckt line
            params = [LSymbol(p.name) for p in stmt.parameters]
            # Add parameters from .param statements inside subcircuit
            extract_subckt_params!(stmt, params)
            code = String(stmt)
            push!(config.subcircuits, (name, ports, params, code))
        elseif isa(stmt, SNode{SC.Subckt})
            name = LSymbol(stmt.name)
            ports = [LSymbol(node) for node in stmt.subckt_nodes.nodes]
            params = Symbol[]
            # Add parameters from .param statements inside subcircuit
            extract_subckt_params!(stmt, params)
            code = String(stmt)
            push!(config.subcircuits, (name, ports, params, code))
        end
    end
    return config.models, config.subcircuits
end

function extract_subckt_params!(subckt, params)
    for stmt in subckt.stmts
        if isa(stmt, SNode{SP.ParamStatement})
            for par in stmt.params
                push!(params, LSymbol(par.name))
            end
        elseif isa(stmt, SNode{SC.Parameters})
            for par in stmt.params
                push!(params, LSymbol(par.name))
            end
        end
    end
end

"""
    resolve_includepath(path, includepaths) -> (ispdk, fullpath)

Resolve an include path by searching in includepaths. 
Returns (false, fullpath) when found.
"""
function resolve_includepath(path, includepaths)
    isfile(path) && return false, path
    for base in includepaths
        fullpath = joinpath(base, path)
        isfile(fullpath) && return false, fullpath
    end
    error("include path $path not found in $includepaths")
end

"""
    extract_section_from_lib(p; section) -> SNode or nothing

Extract a specific .lib section from a parsed SPICE file.
"""
function extract_section_from_lib(p; section)
    for node in p.stmts
        if isa(node, SNode{SP.LibStatement})
            if lowercase(String(node.name)) == lowercase(section)
                return node
            end
        end
    end
    return nothing
end

"""
    to_mosaic_format(models, subcircuits; source_file=nothing, base_category=String[], mode=:inline, archive_url=nothing)

Convert extracted SPICE/Spectre definitions to Mosaic model database format.

Returns a vector of model definitions in CouchDB format with _id keys.
Each model/subcircuit becomes an entry with a generated _id.

Parameters:
- models: Vector of (name, type, subtype, code) tuples from extract_definitions
- subcircuits: Vector of (name, ports, parameters, code) tuples from extract_definitions  
- source_file: Optional source filename for metadata
- base_category: Base category path as vector of strings
- mode: Either :inline (embed code directly), :include (use .include), or :lib (use .lib with {corner})
- archive_url: For include/lib modes, the archive URL in zipurl#archive/path format

Returns Vector{Dict} with model definitions including _id keys.
"""
function to_mosaic_format(models, subcircuits; source_file=nothing, base_category=String[], mode=:inline, archive_url=nothing)
    result = Vector{Dict{String, Any}}()
    
    # Convert models (SPICE .model statements)
    for (name, typ, subtype, code) in models
        model_id = "models:" * string(uuid4())
        
        # Map SPICE device types directly to Mosaic types, using subtype for polarity
        mosaic_type = device_type_mapping(typ, subtype)
        
        # Generate template code based on mode
        template_code = generate_template_code(code, mode, archive_url, source_file)
        
        model_def = Dict{String, Any}(
            "_id" => model_id,
            "name" => string(name),
            "type" => mosaic_type,
            "category" => base_category,  # Put models in Models subcategory
            # SPICE models define device templates, not schematic circuits  
            "templates" => Dict(
                "spice" => [Dict(
                    "name" => "default",
                    "code" => template_code,
                    "use-x" => false
                )],
                "spectre" => Vector{Dict{String,Any}}(),
                "verilog" => Vector{Dict{String,Any}}(),
                "vhdl" => Vector{Dict{String,Any}}()
            ),
            # TODO: Extract parameter info from model statement
            "props" => Vector{Dict{String,Any}}()
        )
        
        # Add source file info if available
        if source_file !== nothing
            model_def["category"] = vcat(base_category, [basename(source_file)])
        end
        
        push!(result, model_def)
    end
    
    # Convert subcircuits  
    for (name, ports, parameters, code) in subcircuits
        model_id = "models:" * string(uuid4())
        
        # Determine port layout using heuristics based on port names
        port_layout = determine_port_layout(ports)
        
        # Generate template code based on mode
        template_code = generate_template_code(code, mode, archive_url, source_file)
        
        model_def = Dict{String, Any}(
            "_id" => model_id,
            "name" => string(name),
            "type" => "ckt",  # subcircuits are always circuit type
            "category" => base_category,
            "ports" => port_layout,
            "templates" => Dict(
                "spice" => [Dict(
                    "name" => "default", 
                    "code" => template_code,
                    "use-x" => true  # subcircuits always use X prefix
                )],
                "spectre" => Vector{Dict{String,Any}}(),
                "verilog" => Vector{Dict{String,Any}}(),
                "vhdl" => Vector{Dict{String,Any}}()
            ),
            # Convert parameter names to props format
            "props" => [Dict("name" => string(param), "tooltip" => "") for param in parameters]
        )
        
        # Add source file info if available  
        if source_file !== nothing
            model_def["category"] = vcat(base_category, [basename(source_file)])
        end
        
        push!(result, model_def)
    end
    
    return result
end

# Helper function to map SPICE device types directly to Mosaic types
"""
    determine_port_layout(ports::Vector{Symbol}) -> Dict{String, Vector{String}}

Determine the layout of ports based on naming patterns and heuristics.

Port placement rules:
- LEFT: ports containing "in", "fb", "ref", "adj", "en", "enable"  
- RIGHT: ports containing "out"
- TOP: "vcc", "vdd", "v+", "hv", "vb", "hb"
- BOTTOM: "gnd", "ground", "com", "vss", "vee", "v-"
- Unassigned ports: split in half between left and right
"""
function determine_port_layout(ports::Vector{Symbol})
    layout = Dict(
        "top" => String[],
        "bottom" => String[], 
        "left" => String[],
        "right" => String[]
    )
    
    unassigned = Symbol[]
    
    for port in ports
        port_str = lowercase(string(port))
        
        # Check for clear functional patterns first
        if contains(port_str, "in") || port_str in ["fb", "ref", "adj", "en", "enable"]
            push!(layout["left"], string(port))
        elseif contains(port_str, "out")
            push!(layout["right"], string(port))
        elseif port_str in ["vcc", "vdd", "v+", "hv", "vb", "hb"]
            push!(layout["top"], string(port))
        elseif port_str in ["gnd", "ground", "com", "vss", "vee", "v-"]
            push!(layout["bottom"], string(port))
        else
            push!(unassigned, port)
        end
    end
    
    # Distribute unassigned ports by splitting in half between left and right
    if !isempty(unassigned)
        mid_point = div(length(unassigned), 2)
        append!(layout["left"], string.(unassigned[1:mid_point]))
        append!(layout["right"], string.(unassigned[mid_point+1:end]))
    end
    
    return layout
end

# Helper function to map SPICE device types directly to Mosaic types
function device_type_mapping(spice_type::Symbol, subtype::Symbol=spice_type)
    spice_str = lowercase(string(spice_type))
    
    # Basic passive components
    if spice_str in ["r", "res"]
        return "resistor"
    elseif spice_str == "c"
        return "capacitor"  
    elseif spice_str == "l"
        return "inductor"
    
    # Diodes
    elseif spice_str == "d"
        return "diode"
    
    # BJT transistors
    elseif spice_str == "npn"
        return "npn"
    elseif spice_str == "pnp"
        return "pnp"
    
    # MOSFET transistors
    elseif spice_str == "nmos"
        return "nmos"
    elseif spice_str == "pmos" 
        return "pmos"
    elseif spice_str == "vdmos"
        return subtype == :pmos ? "pmos" : "nmos"  # Use detected polarity
    
    # JFET transistors - map to BJT as reasonable fallback
    elseif spice_str == "njf"
        return "npn"
    elseif spice_str == "pjf"
        return "pnp"
    
    # MESFET transistors - map to MOSFET as reasonable fallback
    elseif spice_str == "nmf"
        return "nmos"
    elseif spice_str == "pmf"
        return "pmos"
    
    # Unsupported types
    elseif spice_str in ["sw", "csw", "urc", "ltra", "vswitch"]
        error("Unsupported SPICE model type: $spice_str. Switches and transmission lines are not supported in Mosaic format.")
    
    # Unknown types
    else
        error("Unknown SPICE model type: $spice_str. Supported types are: R, RES, C, L, D, NPN, PNP, NMOS, PMOS, VDMOS, NJF, PJF, NMF, PMF")
    end
end

"""
    process_archive(config::ArchiveConfig)

Process an archive using the specified configuration.
"""
function process_archive(config::ArchiveConfig)
    result = Vector{Dict{String, Any}}()
    
    # Create temporary directory for extraction
    temp_dir = mktempdir()
    
    try
        # Download archive
        println("Downloading archive from $(config.url)...")
        archive_file = joinpath(temp_dir, "archive")
        Downloads.download(config.url, archive_file)
        
        # Extract archive using p7zip (handles zip, tar.gz, 7z, etc.)
        extract_dir = joinpath(temp_dir, "extracted")
        mkdir(extract_dir)
        println("Extracting archive...")
        
        # Use p7zip to extract
        p7zip_exe = p7zip_jll.p7zip_path
        run(`$p7zip_exe x $archive_file -o$extract_dir -y`)
        
        # Find files to process
        matching_files = Pair{String,String}[]  # full_path => relative_path
        
        if config.entrypoints === nothing
            # Auto-discover SPICE files by walking directory tree
            spice_extensions = [".mod", ".sp", ".lib", ".cir", ".inc", ".txt"]
            
            for (root, dirs, files) in walkdir(extract_dir)
                for file in files
                    _, ext = splitext(lowercase(file))
                    if ext in spice_extensions
                        full_path = joinpath(root, file)
                        relative_path = relpath(full_path, extract_dir)
                        push!(matching_files, full_path => relative_path)
                    end
                end
            end
        else
            # Use specific relative paths provided by user
            for relative_path in config.entrypoints
                full_path = joinpath(extract_dir, relative_path)
                if isfile(full_path)
                    push!(matching_files, full_path => relative_path)
                else
                    println("Warning: specified file not found: $relative_path")
                end
            end
        end
        
        println("Found $(length(matching_files)) matching files")
        
        # Process each matching file
        for (full_path, relative_path) in matching_files
            println("Processing $relative_path...")
            
            try
                # Extract definitions from file
                models, subcircuits = extract_definitions_from_file(full_path; lib_section=config.lib_section, max_depth=config.max_depth)
                
                if !isempty(models) || !isempty(subcircuits)
                    # Convert to Mosaic format with archive URL
                    file_result = to_mosaic_format(
                        models, subcircuits;
                        source_file=relative_path,
                        base_category=config.base_category,
                        mode=config.mode,
                        archive_url=config.url
                    )
                    
                    # Append results
                    append!(result, file_result)
                    
                    println("  - Found $(length(models)) models, $(length(subcircuits)) subcircuits")
                end
            catch e
                println("  - Error parsing $relative_path: $e")
            end
        end
        
    finally
        # Clean up temporary directory
        rm(temp_dir, recursive=true, force=true)
    end
    
    println("Archive processing complete. Generated $(length(result)) total model entries.")
    return result
end


export extract_definitions, extract_definitions_from_file, to_mosaic_format, process_archive, ArchiveConfig, ExtractionConfig

end # module SpiceArmyKnife
