# TODO:
# - Move endl inline
# - Nodes can be integers

import ...@case

function parse_spice_toplevel(ps)::EXPR
    ex = @case kind(nt(ps)) begin
        SIMULATOR => parse_simulator(ps)
        DOT => parse_dot(ps)
        TITLE_LINE => parse_title(ps)
        NEWLINE => error("internal error: forgot to eat a newline?")
    end
    ex === nothing || return ex
    if is_ident(kind(nt(ps)))
        return parse_instance(ps)
    end
    error!(ps, UnexpectedToken)
end


function parse_dot(ps)
    dot = take(ps, DOT)
    @lift parse_dot(ps, dot)
end

function parse_dot(ps, dot)
    @case kind(nt(ps)) begin
        DC => parse_dc(ps, dot)
        AC => parse_ac(ps, dot)
        LIB => parse_lib(ps, dot)
        END => parse_end(ps, dot)
        ENDL => parse_endl(ps, dot) # Only when parsing a library?
        INCLUDE => parse_include(ps, dot)
        PARAMETERS => parse_param(ps, dot)
        CSPARAM => parse_csparam(ps, dot)
        SUBCKT => parse_subckt(ps, dot)
        MODEL => parse_model(ps, dot)
        OPTIONS => parse_options(ps, dot)
        TITLE => parse_title(ps, dot)
        GLOBAL => parse_global(ps, dot)
        DATA => parse_data(ps, dot)
        IC   => parse_ic(ps, dot)
        MEASURE => parse_measure(ps, dot)
        TRAN => parse_tran(ps, dot)
        PRINT => parse_print(ps, dot)
        TEMP => parse_temp(ps, dot)
        WIDTH => parse_width(ps, dot)
        HDL => parse_hdl(ps, dot)
        IF => parse_if(ps, dot)
        _ =>  error!(ps, UnexpectedToken)
    end
end

function parse_title(ps, dot)
    kw = @lift take_kw(ps, TITLE)
    line = nothing
    if kind(nt(ps)) == TITLE_LINE
        line = @lift take(ps, TITLE_LINE)
    end
    nl = @lift accept_newline(ps)
    return EXPR(Title(dot, kw, line, nl))
end

function parse_title(ps)
    line = @lift take(ps, TITLE_LINE)
    nl = @lift accept_newline(ps)
    return EXPR(Title(nothing, nothing, line, nl))
end

function parse_tran(ps, dot)
    kw = @lift take_kw(ps, TRAN)
    tstep_or_stop = @lift take_literal(ps)
    tstop = if is_literal(kind(nt(ps)))
        tstep = tstep_or_stop
        @lift take_literal(ps)
    else
        tstep = nothing
        tstep_or_stop
    end
    tstart = if is_literal(kind(nt(ps)))
        @lift take_literal(ps)
    end
    tmax = if is_literal(kind(nt(ps)))
        @lift take_literal(ps)
    end
    uic = if is_ident(kind(nt(ps)))
        @lift take_identifier(ps)
    end
    nl = @lift accept_newline(ps)
    if tstep === nothing && ps.lexer.strict && (ps.lexer.spice_dialect in (:ngspice, :hspice))
        return @lift error!(ps, StrictModeViolation)
    end
    return EXPR(Tran(dot, kw, tstep, tstop, tstart, tmax, uic, nl))
end

function parse_measure(ps, dot)
    kw = @lift take_kw(ps, MEASURE)
    type = @lift take_kw(ps, (AC, DC, OP, TRAN, TF, NOISE))
    name = if kind(nt(ps)) == STRING
        @lift take_string(ps)
    else
        @lift take_identifier(ps)
    end

    if kind(nt(ps)) in (FIND, DERIV, PARAMETERS, WHEN, AT)
        return @lift parse_measure_point(ps, dot, kw, type, name)
    else
        return @lift parse_measure_range(ps, dot, kw, type, name)
    end
end

function parse_trig_targ(ps)
    kw = @lift take_kw(ps, (TRIG, TARG))
    lhs = @lift parse_expression(ps)

    val = nothing
    if kind(nt(ps)) == VAL
        val_kw = @lift take_kw(ps)
        eq = @lift take(ps, EQ)
        rhs = @lift parse_expression(ps)
        val = @lift EXPR(Val_(val_kw, eq, rhs))
    end

    td = nothing
    if kind(nt(ps)) == TD
        td = @lift parse_td(ps)
    end

    rfc = nothing
    if kind(nt(ps)) in (RISE, FALL, CROSS)
        rfc = parse_risefallcross(ps)
    end
    return EXPR(TrigTarg(kw, lhs, val, td, rfc))
end

function parse_measure_range(ps, dot, kw, type, name)
    avgmaxminpprmsinteg = nothing

    avgmaxminpprmsinteg = nothing
    if kind(nt(ps)) in (AVG, MAX, MIN, PP, RMS, INTEG)
        kw_op = @lift take_kw(ps)
        expr = @lift parse_expression(ps)
        avgmaxminpprmsinteg = EXPR(AvgMaxMinPPRmsInteg(kw_op, expr))
    end

    trig = nothing
    targ = nothing
    if kind(nt(ps)) == TRIG
        trig = @lift parse_trig_targ(ps)
    end
    if kind(nt(ps)) == TARG
        targ = @lift parse_trig_targ(ps)
    end

    nl = @lift accept_newline(ps)
    return EXPR(MeasureRangeStatement(dot, kw, type, name, avgmaxminpprmsinteg, trig, targ, nl))
end

function parse_risefallcross(ps)
    rfc_kw = @lift take_kw(ps, (RISE, FALL, CROSS))
    eq_rfc = @lift take(ps, EQ)
    val = if kind(nt(ps)) == LAST
        @lift take_kw(ps)
    else
        @lift take_literal(ps)
    end
    return EXPR(RiseFallCross(rfc_kw, eq_rfc, val))
end

function parse_td(ps)
    td_kw = @lift take_kw(ps, TD)
    eq_td = @lift take(ps, EQ)
    expr = @lift parse_expression(ps)
    return EXPR(TD_(td_kw, eq_td, expr))
end

function parse_measure_point(ps, dot, kw, type, name)
    fdp = nothing
    whenat = nothing
    td = nothing
    rfc = nothing
    if kind(nt(ps)) in (FIND, DERIV, PARAMETERS)
        fdp_kw = @lift take_kw(ps, (FIND, DERIV, PARAMETERS))
        eq = if kind(nt(ps)) == EQ
            @lift take(ps, EQ)
        else
            nothing
        end
        expr = @lift parse_expression(ps)
        fdp = EXPR(FindDerivParam(fdp_kw, eq, expr))
    end
    if kind(nt(ps)) in (WHEN, AT)
        if kind(nt(ps)) == AT
            at_kw = @lift take_kw(ps)
            eq = @lift take(ps, EQ)
            at_expr = @lift parse_expression(ps)
            whenat = EXPR(At(at_kw, eq, at_expr))
        else
            when_kw = @lift take_kw(ps)
            when_expr = @lift parse_expression(ps)
            whenat = EXPR(When(when_kw, when_expr))
        end
    end
    if kind(nt(ps)) in (RISE, FALL, CROSS)
        rfc = @lift parse_risefallcross(ps)
    end
    if kind(nt(ps)) == TD
        td = @lift parse_td(ps)
    end
    nl = @lift accept_newline(ps)
    return EXPR(MeasurePointStatement(dot, kw, type, name, fdp, whenat, rfc, td, nl))
end


function parse_ic_statement(ps)
    if kind(nt(ps)) == STAR
        return EXPR(WildCard(nothing, @lift take(ps, STAR)))
    elseif kind(nt(ps)) == NUMBER
        int = @lift take_literal(ps)
        if kind(nt(ps)) == STAR
            return EXPR(WildCard(int, @lift take(ps, STAR)))
        end
        return int
    elseif is_ident(kind(nt(ps)))
        l = @lift take_identifier(ps)
        if kind(nt(ps)) == COLON
            colon = @lift take(ps, COLON)
            r = @lift take_identifier(ps)
            return EXPR(Coloned(l, colon, r))
        end
        return l
    else
        error("unhandled ic statement")
    end
end

function parse_ic(ps, dot)
    kw = @lift take_kw(ps, IC)
    entries = EXPRList{ICEntry}()
    while !eol(ps)
        name = @lift take_identifier(ps)
        lparen = @lift take(ps, LPAREN)
        arg = @lift parse_ic_statement(ps)

        rparen = @lift take(ps, RPAREN)
        eq = @lift take(ps, EQ)
        val = @lift parse_expression(ps)
        entry = EXPR(ICEntry(name, lparen, arg, rparen, eq, val))
        push!(entries, entry)
    end
    nl = @lift accept_newline(ps)
    return EXPR(ICStatement(dot, kw, entries, nl))
end

function parse_print(ps, dot)
    kw = @lift take_kw(ps, PRINT)
    entries = EXPRList{Any}()
    while !eol(ps)
        push!(entries, @lift parse_expression(ps))
    end
    nl = @lift accept_newline(ps)
    return EXPR(PrintStatement(dot, kw, entries, nl))
end

function parse_data(ps, dot)
    kw = @lift take_kw(ps, DATA)
    blockname = @lift take_identifier(ps)

    n_rows = 0
    row_names = EXPRList{Identifier}()
    while is_ident(kind(nt(ps)))
        push!(row_names, @lift take_identifier(ps))
        n_rows += 1
    end

    values = EXPRList{NumberLiteral}()
    while !eol(ps)
        for i in 1:n_rows
            push!(values, @lift take_literal(ps))  # NumberLiteral directly
        end
    end

    nl = @lift accept_newline(ps)
    dot2 = @lift take(ps, DOT)
    endkw = @lift take_kw(ps, ENDDATA)
    nl2 = @lift accept_newline(ps)
    return EXPR(DataStatement(dot, kw, blockname, row_names, values, nl, dot2, endkw, nl2))
end

function parse_options(ps, dot)
    kw = @lift take_kw(ps, OPTIONS)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(OptionStatement(dot, kw, params, nl))
end

function parse_width(ps, dot)
    kw = @lift take_kw(ps, WIDTH)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(WidthStatement(dot, kw, params, nl))
end

function parse_node(ps)
    if kind(nt(ps)) == NUMBER
        return EXPR(NodeName(@lift take_literal(ps)))
    elseif is_ident(kind(nt(ps)))
        return EXPR(NodeName(@lift take_identifier(ps)))
    else
        error!(ps, UnexpectedToken)
    end
end

function parse_node_list(ps)
    nodes = EXPRList{NodeName}()
    return parse_node_list!(nodes, ps)
end

function parse_node_list!(nodes, ps)
    while !eol(ps)
        p = @lift parse_node(ps)
        push!(nodes, p)
    end
    return nodes
end


function parse_hierarchial_node(ps, name=@lift(parse_node(ps)))
    subnodes = EXPRList{SubNode}()
    while kind(nt(ps)) == DOT
        dot = @lift take(ps, DOT)
        subnode = @lift parse_node(ps)
        push!(subnodes, EXPR(SubNode(dot, subnode)))
    end
    return EXPR(HierarchialNode(name, subnodes))
end

function parse_hierarchial_node_list(ps)
    nodes = EXPRList{HierarchialNode}()
    return parse_hierarchial_node_list!(nodes, ps)
end

function parse_hierarchial_node_list!(nodes, ps)
    while !eol(ps)
        p = @lift parse_hierarchial_node(ps)
        push!(nodes, p)
    end
    return nodes
end

function parse_model(ps, dot)
    kw = @lift take_kw(ps, MODEL)
    name = @lift parse_hierarchial_node(ps)
    typ = @lift take_identifier_or_number(ps)  # Model types can start with digits
    parameters = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Model(dot, kw, name, typ, parameters, nl))
end

function parse_subckt(ps, dot)
    kw = @lift take_kw(ps, SUBCKT)
    name = @lift take_identifier_or_number(ps)
    nodes = EXPRList{NodeName}()
    parameters = EXPRList{Parameter}()
    while !eol(ps)
        if kind(nnt(ps)) == EQ
            @lift parse_parameter_list!(parameters, ps)
        else
            push!(nodes, @lift(parse_node(ps)))
        end
    end
    nl = @lift accept_newline(ps)
    exprs = EXPRList{Any}()
    while true
        if kind(nt(ps)) == DOT
            dot2 = @lift take(ps, DOT)
            if kind(nt(ps)) == ENDS
                ends = @lift take_kw(ps, ENDS)
                name_end = eol(ps) ? nothing : @lift take_identifier_or_number(ps)
                nl2 = @lift accept_newline(ps)
                return EXPR(Subckt(dot, kw, name, nodes, parameters, nl, exprs, dot2, ends, name_end, nl2))
            else
                expr = parse_dot(ps, dot2)
            end
        else
            expr = @lift parse_spice_toplevel(ps)
        end
        push!(exprs, expr)
    end
    error("unreachable")
end

function parse_dc(ps, dot)
    kw = @lift take_kw(ps, DC)
    commands = EXPRList{DCCommand}()
    while !eol(ps)
        command = @lift parse_dc_command(ps)
        push!(commands, command)
    end
    nl = @lift accept_newline(ps)
    return EXPR(DCStatement(dot, kw, commands, nl))
end

function parse_dc_command(ps)
    name = @lift take_identifier(ps)
    start = @lift parse_expression(ps)
    stop = @lift parse_expression(ps)
    step = @lift parse_expression(ps)
    return EXPR(DCCommand(name, start, stop, step))
end

function parse_ac(ps, dot)
    kw = @lift take_kw(ps, AC)
    command = @lift parse_ac_command(ps)
    nl = @lift accept_newline(ps)
    return EXPR(ACStatement(dot, kw, command, nl))
end

function parse_ac_command(ps)
    name = @lift take_identifier(ps) # Should be keyword (lin/dec/oct)?
    n = @lift parse_expression(ps)
    fstart = @lift parse_expression(ps)
    fstop = @lift parse_expression(ps)
    return EXPR(ACCommand(name, n, fstart, fstop))
end

function parse_endl(ps, dot)
    endd = @lift take_kw(ps, ENDL)
    endl_id = nothing
    if is_ident(kind(nt(ps)))
        endl_id = @lift take_identifier(ps)
    end
    nl = @lift accept_newline(ps)
    return EXPR(EndlStatement(dot, endd, endl_id, nl))
end

function parse_lib(ps, dot)
    kw = @lift take_kw(ps, LIB)
    # library section is of the form .lib identifier
    # library include is of the form .lib [string|identifier] identifier
    if !is_ident(kind(nnt(ps)))
        name = @lift take_identifier(ps)
        nl = @lift accept_newline(ps)
        stmt = nothing
        exprs = EXPRList{Any}()
        while true
            # TODO: What can be inside a lib statement?
            stmt = parse_spice_toplevel(ps)
            # Failed to parse toplevel, should have an endl here
            if stmt isa EXPR{EndlStatement}
                break
            end
            push!(exprs, stmt)
        end
        return EXPR(LibStatement(dot, kw, name, nl, exprs, stmt))
    else
        path = @lift take_path(ps)
        name = @lift take_identifier(ps)
        nl = @lift accept_newline(ps)
        return EXPR(LibInclude(dot, kw, path, name, nl))
    end
end

function parse_condition(ps)
    lparen = @lift accept(ps, LPAREN)
    expr = @lift parse_expression(ps)
    rparen = @lift accept(ps, RPAREN)
    return EXPR(Condition(lparen, expr, rparen))
end

function parse_ifelse_block(ps, dot, kw)
    condition = nothing
    if kw.form.kw in (IF, ELSEIF)
        condition = @lift parse_condition(ps)
    end
    nl = @lift accept_newline(ps)
    stmts = EXPRList{Any}()
    while true
        if kind(nt(ps)) == DOT && kind(nnt(ps)) in (ELSE, ELSEIF, ENDIF)
            break
        end
        stmt = @lift parse_spice_toplevel(ps)
        push!(stmts, stmt)
    end
    return EXPR(IfElseCase(dot, kw, condition, nl, stmts))
end

function parse_if(ps, dot)
    kw = take_kw(ps, IF)
    cases = EXPRList{IfElseCase}()
    while true
        push!(cases, @lift parse_ifelse_block(ps, dot, kw))
        dot = take(ps, DOT)
        tok = kind(nt(ps))
        kw = take_kw(ps, (IF, ELSE, ELSEIF, ENDIF))
        tok === ENDIF && break
    end
    nl = @lift accept_newline(ps)
    return EXPR(IfBlock(cases, dot, kw, nl))
end

function parse_primary_or_unary(ps)
    if is_unary_operator(kind(nt(ps)))
        parse_unary_op(ps)
    else
        parse_primary(ps)
    end
end


function parse_unary_op(ps)
    op = @lift take_operator(ps)
    primary = @lift parse_primary(ps)
    return EXPR(UnaryOp(op, primary))
end

function parse_primary(ps)
    if is_number(kind(nt(ps)))
        lit = @lift take_literal(ps)
        # TODO: Units?
        return lit
    elseif is_literal(kind(nt(ps)))
        return @lift take_literal(ps)
    elseif is_ident(kind(nt(ps)))
        id = take_identifier(ps)
        if kind(nt(ps)) == LPAREN
            return @lift parse_function_call(ps, id)
        elseif kind(nt(ps)) == DOT
            return @lift parse_hierarchial_node(ps, EXPR(NodeName(id)))
        else
            return id
        end
    elseif kind(nt(ps)) == STRING
        return @lift take_string(ps)
    elseif kind(nt(ps)) == LSQUARE
        return parse_array(ps)
    elseif is_kw(kind(nt(ps)))
        return @lift take_kw(ps)
    elseif kind(nt(ps)) == LBRACE
        lparen = @lift take(ps, LBRACE)
        e = @lift parse_expression(ps)
        rparen = @lift accept(ps, RBRACE)
        return EXPR(Brace(lparen, e, rparen))
    elseif kind(nt(ps)) == LPAREN
        lparen = @lift take(ps, LPAREN)
        e = @lift parse_expression(ps)
        rparen = @lift accept(ps, RPAREN)
        return EXPR(Parens(lparen, e, rparen))
    elseif kind(nt(ps)) == PRIME
        lparen = @lift take(ps, PRIME)
        e = @lift parse_expression(ps)
        rparen = @lift accept(ps, PRIME)
        return EXPR(Prime(lparen, e, rparen))
    elseif kind(nt(ps)) == JULIA_ESCAPE_BEGIN
        # Switch to julia parser
        contents = ps.srcfile.contents
        # TODO: Could we have a base interface that doesn't require a copy?
        thispos = ps.nnt.startbyte+1
        (je, newpos) = Base.Meta.parse(String(isa(contents, IOBuffer) ? copy(contents.data) : contents), thispos-1; raise=false, greedy=false)
        Base.seek(ps.lexer, newpos-2)
        ps.nnt = Token(JULIA_ESCAPE, Int64(ps.nnt.startbyte), newpos-3)
        ps.nnpos += newpos - thispos - 1
        ps.tok_storage = next_token(ps.lexer)
        open = @lift take(ps, JULIA_ESCAPE_BEGIN)
        body = @lift take_julia_escape_body(ps)
        close = @lift accept(ps, RPAREN)
        return EXPR(JuliaEscape(open, body, close))
    end
    return error!(ps, UnexpectedToken)
end

function parse_comma_list!(parse_item, ps, list)
    comma = nothing
    while true
        ref = parse_item(ps)
        push!(list, EXPR((typeof(list).parameters[1])(comma, ref)))
        kind(nt(ps)) == COMMA || return
        comma = @lift take(ps, COMMA)
    end
    nothing
end

function parse_function_call(ps, name)
    lparen = @lift accept(ps, LPAREN)
    args = EXPRList{FunctionArgs{EXPR}}()
    if kind(nt(ps)) != RPAREN
        parse_comma_list!(parse_expression, ps, args)
    end
    return EXPR(FunctionCall(name, lparen, args, @lift accept(ps, RPAREN)))
end

function parse_array(ps)
    lsquare = @lift accept(ps, LSQUARE)
    args = EXPRList{Any}()
    while kind(nt(ps)) != RSQUARE
        push!(args, @lift parse_expression(ps))
    end
    rsquare = @lift accept(ps, RSQUARE)
    return EXPR(Square(lsquare, args, rsquare))
end

function parse_expression(ps)
    if kind(nt(ps)) == PRIME
        lprime = @lift take(ps, PRIME)
        expr = @lift parse_expression(ps)
        rprime = @lift take(ps, PRIME)
        return EXPR(Prime(lprime, expr, rprime))
    end
    ex = @lift parse_primary_or_unary(ps)
    if is_operator(kind(nt(ps)))
        op = @lift take_operator(ps)
        ex = @lift parse_binop(ps, ex, op)
    end
    if kind(nt(ps)) == CONDITIONAL
        not = @lift take(ps, CONDITIONAL)
        ifcase = @lift parse_expression(ps)
        colon = @lift accept(ps, COLON)
        elsecase = @lift parse_expression(ps)
        ex = EXPR(TernaryExpr(ex, not, ifcase, colon, elsecase))
    end
    return ex
end

function parse_binop(ps, ex, op, opterm = nothing)
    local rhs
    while true
        rhs = @lift parse_primary_or_unary(ps)
        is_operator(kind(nt(ps))) || break
        ntprec = prec(kind(nt(ps)))
        if prec(op) >= ntprec
            ex = EXPR(BinaryExpression(ex, op, rhs))
            (opterm !== nothing && prec(opterm) >= ntprec) && return ex
            op = @lift take_operator(ps)
            continue
        else
            rhs = @lift parse_binop(ps, rhs, @lift(take_operator(ps)), op)
            ex = EXPR(BinaryExpression(ex, op, rhs))
            is_operator(kind(nt(ps))) || return ex
            op = @lift take_operator(ps)
            continue
        end
    end
    ret = EXPR(BinaryExpression(ex, op, rhs))
    return ret
end

function parse_simulator(ps)
    kw = @lift take_kw(ps, SIMULATOR)
    langkw = @lift take_kw(ps, LANG)
    eq = @lift take(ps, EQ)
    if kind(nt(ps)) == SPECTRE
        ps.lang_swapped=true
    end
    lang = @lift take_kw(ps, (SPECTRE, SPICE))
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Simulator(kw, langkw, eq, lang, params, nl))
end


function parse_parameter_list(ps)
    parameters = EXPRList{Parameter}()
    return parse_parameter_list!(parameters, ps)
end

function parse_parameter_list!(parameters, ps)
    while !eol(ps) && kind(nt(ps)) != RPAREN
        p = @lift parse_parameter(ps)
        push!(parameters, p)
    end
    return parameters
end


function parse_parameter_mod(ps)
    # TODO: Lot
    kw = @lift take_kw(ps, DEV)
    slash, distr = nothing, nothing
    if kind(nt(ps)) == SLASH
        slash = @lift take(ps, SLASH)
        distr = @lift take_identifier(ps)
    end
    eq = @lift take(ps, EQ)
    val = @lift parse_expression(ps)
    return EXPR(DevMod(kw, slash, distr, eq, val))
end

function parse_parameter(ps, name = @lift take_identifier(ps))
    eq = nothing
    val = nothing
    mod = nothing
    if kind(nt(ps)) == EQ # flags like savecurrents
        eq = @lift accept(ps, EQ)
        val = @lift parse_expression(ps)
    end
    if kind(nt(ps)) == DEV
        mod = @lift parse_parameter_mod(ps)
    end
    return EXPR(Parameter(name, eq, val, mod))
end


function parse_param(ps, dot)
    kw = @lift take_kw(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(ParamStatement(dot, kw, params, nl))
end

function parse_temp(ps, dot)
    kw = @lift take_kw(ps)
    val = @lift parse_expression(ps)
    nl = @lift accept_newline(ps)
    return EXPR(TempStatement(dot, kw, val, nl))
end

function parse_global(ps, dot)
    kw = @lift take_kw(ps, GLOBAL)
    nodes = @lift parse_node_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(GlobalStatement(dot, kw, nodes, nl))
end

function parse_csparam(ps, dot)
    kw = @lift take_kw(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(ParamStatement(dot, kw, params, nl))
end


function parse_include(ps, dot)
    kw = @lift take_kw(ps, INCLUDE)
    path = @lift take_path(ps)
    nl = @lift accept_newline(ps)
    return EXPR(IncludeStatement(dot, kw, path, nl))
end

function parse_hdl(ps, dot)
    kw = @lift take_kw(ps, HDL)
    path = @lift take_path(ps)
    nl = @lift accept_newline(ps)
    return EXPR(HDLStatement(dot, kw, path, nl))
end


function parse_end(ps, dot)
    endd = @lift take_kw(ps, END)
    nl = @lift accept_newline(ps)
    return EXPR(EndStatement(dot, endd, nl))
end

function parse_instance(ps)
    @case kind(nt(ps)) begin
        IDENTIFIER_RESISTOR => parse_resistor(ps)
        IDENTIFIER_VOLTAGE => parse_voltage(ps)
        IDENTIFIER_CURRENT => parse_current(ps)
        IDENTIFIER_VOLTAGE_CONTROLLED_CURRENT => parse_controlled(ControlledSource{:V, :C}, ps)
        IDENTIFIER_VOLTAGE_CONTROLLED_VOLTAGE => parse_controlled(ControlledSource{:V, :V}, ps)
        IDENTIFIER_CURRENT_CONTROLLED_CURRENT => parse_controlled(ControlledSource{:C, :C}, ps)
        IDENTIFIER_CURRENT_CONTROLLED_VOLTAGE => parse_controlled(ControlledSource{:C, :V}, ps)
        IDENTIFIER_BEHAVIORAL => parse_behavioral(ps)
        IDENTIFIER_MOSFET => parse_mosfet(ps)
        IDENTIFIER_S_PARAMETER_ELEMENT => parse_s_parameter_element(ps)
        IDENTIFIER_SWITCH => parse_switch(ps)
        IDENTIFIER_DIODE => parse_diode(ps)
        IDENTIFIER_CAPACITOR => parse_capacitor(ps)
        IDENTIFIER_LINEAR_INDUCTOR => parse_inductor(ps)
        IDENTIFIER_SUBCIRCUIT_CALL => parse_subckt_call(ps)
        IDENTIFIER_BIPOLAR_TRANSISTOR => parse_bipolar_transistor(ps)
        _ => error!(ps, UnexpectedToken)
    end
end

function parse_julia_device(ps, name, nodes...)
    ns = EXPRList{NodeName}()
    for n in nodes
        push!(ns, n)
    end
    dev = @lift parse_primary(ps)
    nl = @lift accept_newline(ps)
    return EXPR(JuliaDevice(name, ns, dev, nl))
end

function parse_inductor(ps)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)
    val = kind(nnt(ps)) == EQ ? nothing : @lift parse_expression(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Inductor(name, pos, neg, val, params, nl))
end

function parse_controlled(cs::Type{ControlledSource{in, out}}, ps) where {in, out}
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)

    # Check if this is a POLY expression
    if kind(nt(ps)) == POLY
        # Parse POLY expression: POLY(N) control_nodes... coefficients...
        # Note: parentheses are treated as token separators and not emitted as tokens
        poly_token = @lift take_kw(ps, POLY)
        n_dims_token = @lift take_literal(ps)  # Should be a number literal

        # Parse all remaining arguments into one big list
        # This includes: control_nodes + coefficients
        args = EXPRList{Any}()
        while !eol(ps)
            push!(args, @lift parse_expression(ps))
        end

        # Create a special POLY expression structure
        poly_expr = EXPR(PolyControl(poly_token, n_dims_token, args))

        nl = @lift accept_newline(ps)
        return EXPR(cs(name, pos, neg, poly_expr, nl))
    elseif kind(nt(ps)) == TABLE
        # Table controlled source parsing
        table_token = @lift take_kw(ps, TABLE)
        expr = @lift parse_expression(ps)
        eq = if kind(nt(ps)) == EQ
                 @lift accept(ps, EQ)
        end
        # Parse all remaining number pairs into one big list
        args = EXPRList{Any}()
        while !eol(ps)
            push!(args, @lift parse_expression(ps))
        end
        table_expr = EXPR(TableControl(table_token, expr, eq, args))
        nl = @lift accept_newline(ps)
        return EXPR(cs(name, pos, neg, table_expr, nl))
    elseif in == :V
        # Standard voltage controlled source parsing
        cpos = kind(nnt(ps)) == EQ ? nothing : @lift parse_node(ps)
        cneg = kind(nnt(ps)) == EQ ? nothing : @lift parse_node(ps)
        val = kind(nnt(ps)) == EQ ? nothing : @lift parse_expression(ps)
        params = @lift parse_parameter_list(ps)
        expr = EXPR(VoltageControl(cpos, cneg, val, params))
        nl = @lift accept_newline(ps)
        return EXPR(cs(name, pos, neg, expr, nl))
    elseif in == :C
        # Standard current controlled source parsing
        vnam = kind(nnt(ps)) == EQ ? nothing : @lift parse_node(ps)
        val = kind(nnt(ps)) == EQ ? nothing : @lift parse_expression(ps)
        params = @lift parse_parameter_list(ps)
        expr = EXPR(CurrentControl(vnam, val, params))
        nl = @lift accept_newline(ps)
        return EXPR(cs(name, pos, neg, expr, nl))
    end
end

function parse_behavioral(ps)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Behavioral(name, pos, neg, params, nl))
end

parse_voltage(ps) = parse_voltage_or_current(ps, true)
parse_current(ps) = parse_voltage_or_current(ps, false)

function parse_tran_fn(ps)
    kw = @lift take_kw(ps)
    # TODO: Check divisible by two?
    vals = EXPRList{Any}()
    while !eol(ps) && !is_kw(kind(nt(ps)))
        ref = @lift parse_expression(ps)
        push!(vals, ref)
    end
    return EXPR(TranSource(kw, vals))
end

function parse_voltage_or_current(ps, isvoltage)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)
    vals = EXPRList{Union{ACSource, DCSource, TranSource}}()
    while !eol(ps)
        if kind(nt(ps)) == DC
            dc = @lift take_kw(ps, DC)
            eq = if kind(nt(ps)) == EQ
                @lift take(ps, EQ)
            end
            expr = @lift parse_expression(ps)
            push!(vals, EXPR(DCSource(dc, eq, expr)))
        elseif kind(nt(ps)) == AC
            ac = @lift take_kw(ps, AC)
            eq = if kind(nt(ps)) == EQ
                @lift take(ps, EQ)
            end
            expr = @lift parse_expression(ps)
            # TODO Phase
            push!(vals, EXPR(ACSource(ac, eq, expr)))
        elseif is_source_type(kind(nt(ps)))
            push!(vals, @lift parse_tran_fn(ps))
        else
            expr = @lift parse_expression(ps)
            push!(vals, EXPR(DCSource(nothing, nothing, expr)))
        end
    end
    nl = @lift accept_newline(ps)
    T = isvoltage ? Voltage : Current
    return EXPR(T(name, pos, neg, vals, nl))
end


function convert_node_expr_to_identifier(node::EXPR{NodeName})
    return EXPR{Identifier}(node.fullwidth, node.off, node.width, node.name.form)
end

function parse_bipolar_transistor(ps)
    name = @lift parse_node(ps)
    c = @lift parse_node(ps)
    b = @lift parse_node(ps)
    e = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, c, b, e)
    s = @lift parse_node(ps) # or model
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, c, b, e, s)
    if is_ident(kind(nt(ps)))
        model = take_identifier(ps)
        if kind(nt(ps)) == EQ
            param_name = model
            model = @lift convert_node_expr_to_identifier(s)
            s = nothing
            params = EXPRList{Parameter}()
            push!(params, @lift parse_parameter(ps, param_name))
            @lift parse_parameter_list!(params, ps)
        else
            params = @lift parse_parameter_list(ps)
        end
    else
        model = @lift convert_node_expr_to_identifier(s)
        s = nothing
        params = EXPRList{Parameter}()
    end
    nl = @lift accept_newline(ps)
    return EXPR(BipolarTransistor(name, c, b, e, s, model, params, nl))
end

function parse_capacitor(ps)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)
    val = kind(nnt(ps)) == EQ ? nothing : @lift parse_expression(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Capacitor(name, pos, neg, val, params, nl))
end


function parse_diode(ps)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)

    model = @lift take_identifier(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Diode(name, pos, neg, model, params, nl))
end

function parse_resistor(ps)
    name = @lift parse_node(ps)
    pos = @lift parse_node(ps)
    neg = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, pos, neg)
    val = kind(nnt(ps)) == EQ ? nothing : @lift parse_expression(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Resistor(name, pos, neg, val, params, nl))
end


function parse_mosfet(ps)
    name = @lift parse_node(ps)
    d = @lift parse_node(ps)
    g = @lift parse_node(ps)
    s = @lift parse_node(ps)
    b = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, d, g, s, b)
    model = @lift parse_node(ps)
    parameters = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(MOSFET(name, d, g, s, b, model, parameters, nl))
end

function parse_subckt_call(ps)
    name = @lift parse_node(ps)
    nodes = EXPRList{NodeName}()
    while kind(nnt(ps)) !== EQ && kind(nt(ps)) !== NEWLINE && kind(nt(ps)) !== JULIA_ESCAPE_BEGIN
        push!(nodes, @lift parse_node(ps))
    end
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, nodes...)
    model = pop!(nodes)
    parameters = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(SubcktCall(name, nodes, model, parameters, nl))
end

function parse_s_parameter_element(ps)
    name = @lift parse_node(ps)
    nd1 = @lift parse_node(ps)
    nd2 = @lift parse_node(ps)
    model = @lift parse_node(ps)
    parameters = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(SParameterElement(name, nd1, nd2, model, parameters, nl))
end

function parse_switch(ps)
    name = @lift parse_node(ps)
    nd1 = @lift parse_node(ps)
    nd2 = @lift parse_node(ps)
    cnd1 = @lift parse_node(ps)
    cnd2 = @lift parse_node(ps)
    kind(nt(ps)) == JULIA_ESCAPE_BEGIN && return parse_julia_device(ps, name, nd1, nd2, cnd1, cnd2)
    model = @lift parse_node(ps)
    onoff = @lift take_kw(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Switch(name, nd1, nd2, cnd1, cnd2, model, onoff, nl))
end

eol(ps) = (t = nt(ps); kind(t) == NEWLINE || kind(t) == ENDMARKER)


function take_kw(ps)
    kwkind = kind(nt(ps))
    @assert is_kw(kwkind)
    EXPR!(Keyword(kwkind), ps)
end

function take_kw(ps, tkind)
    !isa(tkind, Tuple) && (tkind = (tkind,))
    kwkind = kind(nt(ps))
    @assert is_kw(kwkind) && kwkind in tkind
    EXPR!(Keyword(kwkind), ps)
end

function take_identifier(ps)
    if is_ident(kind(nt(ps)))
        return EXPR!(Identifier(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_identifier_or_number(ps)
    # Accept either an identifier or a number token (for model names like "1N3064")
    if is_ident(kind(nt(ps)))
        return EXPR!(Identifier(), ps)
    elseif kind(nt(ps)) == NUMBER
        return EXPR!(NumberLiteral(), ps)
    else
        error!(ps, UnexpectedToken)
    end
end

function take_literal(ps)
    ntkind = kind(nt(ps))
    if is_literal(ntkind)
        return EXPR!(ntkind == NUMBER ? NumberLiteral() : Literal(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function maybe_take_unit(ps)
    # This function is now a no-op
end

function accept_identifier(ps)
    if kind(nt(ps)) == IDENTIFIER
        return take_identifier(ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function accept(ps, tkind)
    !isa(tkind, Tuple) && (tkind = (tkind,))
    if kind(nt(ps)) in tkind
        return EXPR!(Notation(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function accept_newline(ps)
    if kind(nt(ps)) in (NEWLINE, ENDMARKER)
        return EXPR!(Notation(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function accept_kw(ps, tkind)
    !isa(tkind, Tuple) && (tkind = (tkind,))
    @assert all(is_kw, tkind)
    kwkind = kind(nt(ps))
    if kwkind in tkind
        return EXPR!(Keyword(kwkind), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function accept_kw(ps)
    kwkind = kind(nt(ps))
    if is_kw(kwkind)
        return EXPR!(Keyword(kwkind), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_string(ps)
    if kind(nt(ps)) == STRING
        return EXPR!(StringLiteral(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_path(ps)
    # an unquoted path might be lexed as an identifier
    if is_ident(kind(nt(ps))) || kind(nt(ps)) == STRING
        return EXPR!(StringLiteral(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take(ps, tkind)
    !isa(tkind, Tuple) && (tkind = (tkind,))
    if kind(nt(ps)) in tkind
        return EXPR!(Notation(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_operator(ps)
    ntkind = kind(nt(ps))
    if is_operator(ntkind)
        return EXPR!(Operator(ntkind), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_builtin_func(ps)
    if is_builtin_func(kind(nt(ps)))
        return EXPR!(BuiltinFunc(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_builtin_const(ps)
    if is_builtin_const(kind(nt(ps)))
        return EXPR!(BuiltinConst(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_julia_escape_body(ps)
    if kind(nt(ps)) == JULIA_ESCAPE
        return EXPR!(JuliaEscapeBody(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function error!(ps, kind, expected=nothing)
    ps.errored = true
    prev = ps.pos
    fw = ps.npos - prev
    while !eol(ps)
        next(ps)
    end
    next(ps) # consume newline or endmarker
    offset = UInt32(ps.t.startbyte - prev)
    return EXPR(fw, offset, UInt32(ps.t.endbyte - ps.t.startbyte + 1), Error(kind, expected))
end


@enum(PrecedenceLevels,
    PREC_LOGICAL,
    PREC_AND_AND,
    PREC_OR,
    PREC_XOR,
    PREC_AND,
    PREC_EQ,
    PREC_LT,
    PREC_SHIFT,
    PREC_PLUS,
    PREC_MUL,
    PREC_STAR_STAR)

function prec(opkind::Kind)
    if opkind in (LAZY_OR, EVENT_OR)
        return PREC_LOGICAL
    elseif opkind in (LAZY_AND,)
        return PREC_AND_AND
    elseif opkind in (OR,)
        return PREC_OR
    elseif opkind in (XOR, XOR_TILDE, TILDE_XOR)
        return PREC_XOR
    elseif opkind in (AND,)
        return PREC_AND
    elseif opkind in (EQ, EQEQ, NOT_EQ, EQEQEQ, NOT_EQEQ)
        return PREC_EQ
    elseif opkind in (LESS, GREATER, LESS_EQ, GREATER_EQ)
        return PREC_LT
    elseif opkind in (LBITSHIFT, RBITSHIFT, LBITSHIFT_A, RBITSHIFT_A)
        return PREC_SHIFT
    elseif opkind in (PLUS, MINUS)
        return PREC_PLUS
    elseif opkind in (STAR, SLASH, PERCENT)
        return PREC_MUL
    elseif opkind in (STAR_STAR,)
        return PREC_STAR_STAR
    else
        error("Unknown operator")
    end
end
prec(op::Operator) = prec(op.op)
prec(ex::EXPR{Operator}) = prec(ex.form)
