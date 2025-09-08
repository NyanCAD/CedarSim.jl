#!/usr/bin/env julia

"""
Model Database Generator

This script processes multiple SPICE model archives from various sources
and generates a unified JSON database for CouchDB upload.
"""

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using SpiceArmyKnife
using JSON

function main()
    println("=" ^ 80)
    println("SPICE Model Database Generator")
    println("=" ^ 80)
    
    # Combined results will be accumulated here
    all_models = Vector{Dict{String, Any}}()
    
    # Archive configurations
    # Each entry: (url, entrypoints, category, mode)
    archives = [
        # NGSpice Basic Models - comprehensive collection
        (
            "https://ngspice.sourceforge.io/model-parameters/basic_models.7z",
            nothing,  # Auto-discover all files
            ["NGSpice", "Basic Models"],
            :include
        ),
        
        # Example of processing specific files from an archive
        (
            "https://ngspice.sourceforge.io/model-parameters/basic_models.7z",
            ["basic_models/diodes/1N4148.mod", "basic_models/LED/SnapLED150.mod"],
            ["NGSpice", "Selected Components"],
            :lib
        ),
        
        # Add more archives here as needed:
        # (
        #     "https://example.com/other_models.zip",
        #     ["models/*.lib", "subcircuits/*.sp"],
        #     ["Vendor", "Professional Models"],
        #     :inline
        # ),
    ]
    
    # Process each archive
    for (i, (url, entrypoints, category, mode)) in enumerate(archives)
        println("\nProcessing archive $(i)/$(length(archives)): $url")
        println("Category: $(join(category, " / "))")
        println("Mode: $mode")
        println("Entrypoints: $(entrypoints === nothing ? "auto-discover" : join(entrypoints, ", "))")
        println("-" ^ 60)
        
        try
            models = process_archive(
                url;
                entrypoints=entrypoints,
                base_category=category,
                mode=mode
            )
            
            println("✓ Successfully processed $(length(models)) models")
            append!(all_models, models)
            
        catch e
            println("✗ Error processing archive: $e")
            println("Continuing with next archive...")
        end
    end
    
    # Generate final output
    output_file = "model_database.json"
    println("\n" * "=" ^ 80)
    println("GENERATION COMPLETE")
    println("=" ^ 80)
    println("Total models generated: $(length(all_models))")
    
    # Group by type for summary
    type_counts = Dict{String, Int}()
    for model in all_models
        model_type = model["type"]
        type_counts[model_type] = get(type_counts, model_type, 0) + 1
    end
    
    println("\nBreakdown by type:")
    for (type, count) in sort(collect(type_counts))
        println("  $type: $count models")
    end
    
    # Save to JSON file
    println("\nSaving to $output_file...")
    open(output_file, "w") do io
        JSON.print(io, all_models, 2)  # Pretty-print with 2-space indent
    end
    
    file_size_kb = round(stat(output_file).size / 1024, digits=1)
    println("✓ Saved $(length(all_models)) models to $output_file ($(file_size_kb) KB)")
    
    # Show sample models
    println("\nSample models:")
    for model in first(all_models, min(3, length(all_models)))
        println("  - $(model["name"]) ($(model["type"]))")
        println("    Category: $(join(model["category"], " / "))")
        println("    ID: $(model["_id"])")
    end
    
    println("\n" * "=" ^ 80)
    println("Ready for CouchDB upload!")
    println("Use: curl -X POST http://couchdb:5984/models/_bulk_docs -d @$output_file -H 'Content-Type: application/json'")
    println("=" ^ 80)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end