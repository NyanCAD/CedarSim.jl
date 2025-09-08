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
    extract_definitions_from_file(filepath::String) -> (models, subcircuits)

Parse a SPICE/Spectre file and extract model and subcircuit definitions.
Uses automatic file extension detection (.scs = Spectre, others = SPICE).
"""
function extract_definitions_from_file(filepath::String)
    ast = SpectreNetlistParser.parsefile(filepath)
    return extract_definitions(ast)
end

"""
    extract_definitions(ast; models = [], subcircuits = [])

Extract model and subcircuit definitions from a SPICE/Spectre AST.
Returns models as (name, type, code) tuples and subcircuits as (name, ports, parameters, code) tuples.
For subcircuits, parameters is a list of parameter names from both subckt line and .param statements inside.
Code is the full source text extracted using String(node).
"""
function extract_definitions(ast; models = [], subcircuits = [])
    for stmt in ast.stmts
        if isa(stmt, SNode{SPICENetlistSource})
            # Recurse into netlist source nodes
            extract_definitions(stmt; models, subcircuits)
        elseif isa(stmt, SNode{SP.Model})
            name = LSymbol(stmt.name)
            typ = LSymbol(stmt.typ)
            code = String(stmt)
            push!(models, (name, typ, code))
        elseif isa(stmt, SNode{SC.Model})
            name = LSymbol(stmt.name)
            typ = LSymbol(stmt.master_name)
            code = String(stmt)
            push!(models, (name, typ, code))
        elseif isa(stmt, SNode{SP.Subckt})
            name = LSymbol(stmt.name)
            ports = [LSymbol(node.name) for node in stmt.subckt_nodes]
            # Start with parameters from subckt line
            params = [LSymbol(p.name) for p in stmt.parameters]
            # Add parameters from .param statements inside subcircuit
            extract_subckt_params!(stmt, params)
            code = String(stmt)
            push!(subcircuits, (name, ports, params, code))
        elseif isa(stmt, SNode{SC.Subckt})
            name = LSymbol(stmt.name)
            ports = [LSymbol(node) for node in stmt.subckt_nodes.nodes]
            params = Symbol[]
            # Add parameters from .param statements inside subcircuit
            extract_subckt_params!(stmt, params)
            code = String(stmt)
            push!(subcircuits, (name, ports, params, code))
        end
    end
    return models, subcircuits
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
    to_mosaic_format(models, subcircuits; source_file=nothing, base_category=String[], mode=:inline, archive_url=nothing)

Convert extracted SPICE/Spectre definitions to Mosaic model database format.

Returns a vector of model definitions in CouchDB format with _id keys.
Each model/subcircuit becomes an entry with a generated _id.

Parameters:
- models: Vector of (name, type, code) tuples from extract_definitions
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
    for (name, typ, code) in models
        model_id = "models:" * string(uuid4())
        
        # Map SPICE device types to Mosaic types
        device_mapping = device_type_mapping(typ)
        mosaic_type = if device_mapping == :d
            "diode"
        elseif device_mapping == :r
            "resistor"  
        elseif device_mapping == :c
            "capacitor"
        elseif device_mapping == :l
            "inductor"
        elseif device_mapping == :npn
            "npn"
        elseif device_mapping == :pnp
            "pnp"
        elseif device_mapping == :nmos
            "nmos"
        elseif device_mapping == :pmos
            "pmos"
        else
            "ckt"  # fallback for unknown types
        end
        
        # Generate template code based on mode
        template_code = generate_template_code(code, mode, archive_url, source_file)
        
        model_def = Dict{String, Any}(
            "_id" => model_id,
            "name" => string(name),
            "type" => mosaic_type,
            "category" => vcat(base_category, ["Models"]),  # Put models in Models subcategory
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
            model_def["category"] = vcat(base_category, [basename(source_file), "Models"])
        end
        
        push!(result, model_def)
    end
    
    # Convert subcircuits  
    for (name, ports, parameters, code) in subcircuits
        model_id = "models:" * string(uuid4())
        
        # Determine port layout - for now put all ports on left/right
        # TODO: Implement smarter port placement based on port names or hints
        mid_point = div(length(ports), 2)
        port_layout = Dict(
            "top" => String[],
            "bottom" => String[], 
            "left" => string.(ports[1:mid_point]),
            "right" => string.(ports[mid_point+1:end])
        )
        
        # Generate template code based on mode
        template_code = generate_template_code(code, mode, archive_url, source_file)
        
        model_def = Dict{String, Any}(
            "_id" => model_id,
            "name" => string(name),
            "type" => "ckt",  # subcircuits are always circuit type
            "category" => vcat(base_category, ["Subcircuits"]),
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
            model_def["category"] = vcat(base_category, [basename(source_file), "Subcircuits"])
        end
        
        push!(result, model_def)
    end
    
    return result
end

# Helper function to map SPICE device types  
function device_type_mapping(spice_type::Symbol)
    # Handle common SPICE device type mappings
    spice_str = lowercase(string(spice_type))
    if spice_str == "d"
        return :d
    elseif spice_str == "r" 
        return :r
    elseif spice_str == "c"
        return :c  
    elseif spice_str == "l"
        return :l
    elseif spice_str in ["nmos", "nch"]
        return :nmos
    elseif spice_str in ["pmos", "pch"] 
        return :pmos
    elseif spice_str in ["npn", "bjt_npn"]
        return :npn
    elseif spice_str in ["pnp", "bjt_pnp"]
        return :pnp
    else
        return :unknown
    end
end

"""
    process_archive(archive_url::String; entrypoints=nothing, base_category=String[], mode=:include)

Download an archive from a URL, extract it, find model/subcircuit files, parse them, and generate a Mosaic model database.

Parameters:
- archive_url: URL to download archive from
- entrypoints: Either Vector{String} of specific relative paths in archive, or nothing to auto-discover files
- base_category: Base category path for Mosaic format
- mode: Template mode (:inline, :include, :lib)

If entrypoints is nothing, automatically finds files with extensions: .mod, .sp, .lib, .cir, .inc, .txt
If entrypoints is a vector of strings, treats them as specific relative paths within the archive.

Returns Vector{Dict} with model definitions including _id keys.
"""
function process_archive(archive_url::String; entrypoints=nothing, base_category=String[], mode=:include)
    result = Vector{Dict{String, Any}}()
    
    # Create temporary directory for extraction
    temp_dir = mktempdir()
    
    try
        # Download archive
        println("Downloading archive from $archive_url...")
        archive_file = joinpath(temp_dir, "archive")
        Downloads.download(archive_url, archive_file)
        
        # Extract archive using p7zip (handles zip, tar.gz, 7z, etc.)
        extract_dir = joinpath(temp_dir, "extracted")
        mkdir(extract_dir)
        println("Extracting archive...")
        
        # Use p7zip to extract
        p7zip_exe = p7zip_jll.p7zip_path
        run(`$p7zip_exe x $archive_file -o$extract_dir -y`)
        
        # Find files to process
        matching_files = Pair{String,String}[]  # full_path => relative_path
        
        if entrypoints === nothing
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
            for relative_path in entrypoints
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
                models, subcircuits = extract_definitions_from_file(full_path)
                
                if !isempty(models) || !isempty(subcircuits)
                    # Convert to Mosaic format with archive URL
                    file_result = to_mosaic_format(
                        models, subcircuits;
                        source_file=relative_path,
                        base_category=base_category,
                        mode=mode,
                        archive_url=archive_url
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

export extract_definitions, extract_definitions_from_file, to_mosaic_format, process_archive

end # module SpiceArmyKnife
