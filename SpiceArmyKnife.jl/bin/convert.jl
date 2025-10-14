#!/usr/bin/env julia

"""
SPICE/Spectre Netlist Converter

Convert netlists between different SPICE/Spectre dialects with parameter filtering
and format adjustments.

Usage:
    julia convert.jl input.sp output.sp --output-dialect ngspice
    julia convert.jl circuit.sp circuit.scs --output-lang spectre --output-dialect spectre

Examples:
    # Convert Cordell models to ngspice-compatible format (filters doc parameters)
    julia convert.jl Cordell-Models.txt ngspice-models.sp --output-dialect ngspice

    # Convert SPICE to Spectre format
    julia convert.jl circuit.sp circuit.scs --output-lang spectre --output-dialect spectre

    # Explicitly specify input format
    julia convert.jl input.cir output.sp --input-lang spice --input-dialect hspice --output-dialect ngspice
"""

using SpiceArmyKnife
using SpectreNetlistParser
using ArgParse

function detect_language(filepath::String)
    ext = lowercase(splitext(filepath)[2])
    if ext in [".sp", ".spi", ".spice", ".cir", ".lib"]
        return :spice
    elseif ext in [".scs", ".spectre"]
        return :spectre
    else
        # Default to SPICE for unknown extensions
        return :spice
    end
end

function parse_commandline()
    s = ArgParseSettings(
        description = "Convert SPICE/Spectre netlists between different dialects",
        epilog = """
            Examples:
              # Convert to ngspice (filters documentation parameters)
              \$ julia convert.jl models.txt ngspice-models.sp --output-dialect ngspice

              # Convert SPICE to Spectre
              \$ julia convert.jl circuit.sp circuit.scs --output-lang spectre --output-dialect spectre

              # Specify all parameters
              \$ julia convert.jl input.cir output.sp --input-lang spice --input-dialect hspice --output-dialect ngspice
            """
    )

    @add_arg_table! s begin
        "input"
            help = "Input netlist file"
            required = true
        "output"
            help = "Output netlist file"
            required = true
        "--input-lang", "-i"
            help = "Input language: spice or spectre (default: auto-detect from extension)"
            arg_type = Symbol
            default = nothing
        "--input-dialect"
            help = "Input dialect (default: generic)"
            arg_type = Symbol
            default = :generic
        "--output-lang", "-o"
            help = "Output language: spice or spectre (default: same as input)"
            arg_type = Symbol
            default = nothing
        "--output-dialect", "-d"
            help = "Output dialect: ngspice, hspice, pspice, spectre, etc. (required)"
            arg_type = Symbol
            required = true
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()

    input_file = args["input"]
    output_file = args["output"]
    input_lang = args["input-lang"]
    input_dialect = args["input-dialect"]
    output_lang = args["output-lang"]
    output_dialect = args["output-dialect"]

    # Validate input file
    if !isfile(input_file)
        println("Error: Input file not found: $input_file")
        exit(1)
    end

    # Auto-detect input language if not specified
    if input_lang === nothing
        input_lang = detect_language(input_file)
        println("Auto-detected input language: $input_lang")
    end

    # Default output language to input language
    if output_lang === nothing
        output_lang = input_lang
    end

    println("=" ^ 80)
    println("SPICE/Spectre Netlist Converter")
    println("=" ^ 80)
    println("Input:  $input_file ($input_lang/$input_dialect)")
    println("Output: $output_file ($output_lang/$output_dialect)")
    println("-" ^ 80)

    try
        # Parse input file
        println("Parsing input file...")
        ast = if input_lang == :spice
            SpectreNetlistParser.parsefile(input_file; start_lang=:spice, implicit_title=true)
        else
            SpectreNetlistParser.parsefile(input_file; start_lang=:spectre)
        end

        if ast.ps.errored
            println("⚠ Warning: Parse errors encountered in input file")
            println("  Attempting to generate output anyway...")
        else
            println("✓ Successfully parsed input file")
        end

        # Generate output
        println("Generating output code...")
        output_code = generate_code(ast, output_lang, output_dialect)

        # Write output file
        println("Writing output file...")
        open(output_file, "w") do io
            write(io, output_code)
        end

        file_size_kb = round(stat(output_file).size / 1024, digits=1)
        println("✓ Successfully wrote $output_file ($(file_size_kb) KB)")

        # Show what changed if ngspice filtering was applied
        if output_dialect == :ngspice && output_lang == :spice
            println("\nNote: ngspice dialect filtering applied:")
            println("  - Removed documentation parameters: iave, vpk, mfg, type, icrating, vceo")
        end

        println("=" ^ 80)
        println("✓ CONVERSION COMPLETE")
        println("=" ^ 80)

    catch e
        println("=" ^ 80)
        println("✗ CONVERSION FAILED")
        println("=" ^ 80)
        showerror(stdout, e, catch_backtrace())
        println()
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
