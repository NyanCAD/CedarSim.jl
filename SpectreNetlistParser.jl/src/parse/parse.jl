import ..@case

function parse_spectrenetlist_source(ps)::EXPR
    ex = @case kind(nt(ps)) begin
        SIMULATOR => parse_simulator(ps)
        MODEL => parse_model(ps)
        INCLUDE => parse_include(ps)
        AHDL_INCLUDE => parse_ahdl_include(ps)
        GLOBAL => parse_global(ps)

        PARAMETERS => parse_parameters(ps)

        INLINE => parse_subckt(ps, @lift(take_kw(ps, INLINE)))
        SUBCKT => parse_subckt(ps)
        # Control
        SAVE => parse_save(ps)
        IC => parse_ic(ps)
        NODESET => parse_nodeset(ps)
        #
        REAL => parse_function_decl(ps)
        #
        IF => parse_conditional_block(ps)

        # Error
        NEWLINE => error("internal error: forgot to eat a newline?")
    end
    ex === nothing || return ex
    if is_ident(kind(nt(ps)))
        return parse_other(ps)
    end
    return error!(ps, UnexpectedToken)
end

function parse_conditional_block(ps)
    aif = @lift parse_if(ps)
    cases = EXPRList{ElseIf}()
    aelse = nothing
    while kind(nt(ps)) == ELSE
        kw = @lift take_kw(ps, ELSE)
        if kind(nt(ps)) == IF
            stmt = @lift parse_elseif(ps, kw)
            push!(cases, stmt)
        else
            aelse = @lift parse_else(ps, kw)
            break
        end
    end
    nl = @lift accept_newline(ps)
    return EXPR(ConditionalBlock(aif, cases, aelse, nl))
end

function parse_if(ps)
    kw = @lift take_kw(ps, IF)
    lparen = @lift accept(ps, LPAREN)
    expr = @lift parse_expression(ps)
    rparen = @lift accept(ps, RPAREN)
    lbrace = @lift accept(ps, LBRACE)
    nl = @lift accept_newline(ps)
    name = @lift take_identifier(ps)
    stmt = @lift parse_instance(ps, name)
    rbrace = @lift accept(ps, RBRACE)
    return EXPR(If(kw, lparen, expr, rparen, lbrace, nl, stmt, rbrace))
end

function parse_elseif(ps, kw)
    kw2 = @lift take_kw(ps, IF)
    lparen = @lift accept(ps, LPAREN)
    expr = @lift parse_expression(ps)
    rparen = @lift accept(ps, RPAREN)
    lbrace = @lift accept(ps, LBRACE)
    nl = @lift accept_newline(ps)
    name = @lift take_identifier(ps)
    stmt = @lift parse_instance(ps, name)
    rbrace = @lift accept(ps, RBRACE)
    return EXPR(ElseIf(kw, kw2, lparen, expr, rparen, lbrace, nl, stmt, rbrace))
end

function parse_else(ps, kw)
    lbrace = @lift accept(ps, LBRACE)
    nl = @lift accept_newline(ps)
    name = @lift take_identifier(ps)
    stmt = @lift parse_instance(ps, name)
    rbrace = @lift accept(ps, RBRACE)
    return EXPR(Else(kw, lbrace, nl, stmt, rbrace))
end



function parse_function_decl_arg(ps)
    typ = @lift take_kw(ps, REAL)
    id = @lift take_identifier(ps)
    return EXPR(FunctionDeclArg(typ, id))
end

function parse_function_decl(ps)
    rtype = @lift take_kw(ps, REAL)
    id = @lift take_identifier(ps)
    lparen = @lift take(ps, LPAREN)
    args = EXPRList{FunctionArgs{EXPR{FunctionDeclArg}}}()
    if kind(nt(ps)) != RPAREN
        @lift parse_comma_list!(parse_function_decl_arg, ps, args)
    end
    rparen = @lift take(ps, RPAREN)
    lbrace = @lift take(ps, LBRACE)
    nl1 = @lift take(ps, NEWLINE)
    ret = @lift take_kw(ps, RETURN)
    exp = @lift parse_expression(ps)
    semicolon = @lift take(ps, SEMICOLON)
    nl2 = @lift take(ps, NEWLINE)
    rbrace = @lift take(ps, RBRACE)
    nl3 = @lift take(ps, NEWLINE)
    return EXPR(FunctionDecl(rtype, id, lparen, args, rparen, lbrace, nl1, ret, exp, semicolon, nl2, rbrace, nl3))
end

function parse_subckt(ps, inline::Union{Nothing,EXPR}=nothing)
    kw = @lift accept_kw(ps, SUBCKT)
    name = @lift accept_identifier(ps)
    subckt_nodes = if kind(nt(ps)) == LPAREN
        lparen = @lift accept(ps, LPAREN)
        nodes = @lift parse_nodes(ps)
        rparen = @lift accept(ps, RPAREN)
        EXPR(SubcktNodes(lparen, nodes, rparen))
    else
        nodes = @lift parse_nodes(ps)
        if isempty(nodes)
            nothing
        else
            EXPR(SubcktNodes(nothing, nodes, nothing))
        end
    end
    nl = @lift accept_newline(ps)
    exprs = EXPRList{Any}()
    while kind(nt(ps)) != ENDS
        expr = @lift parse_spectrenetlist_source(ps)
        push!(exprs, expr)
    end
    ends = @lift accept_kw(ps, ENDS)
    end_name = nothing
    if kind(nt(ps)) == IDENTIFIER
        end_name = @lift take_identifier(ps)
    end
    nl2 = @lift accept_newline(ps)
    return EXPR(Subckt(inline, kw, name, subckt_nodes, nl, exprs, ends, end_name, nl2))
end

function parse_paramtest(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, PARAMTEST)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(ParamTest(name, kw, params, nl))
end

function parse_node(ps)
    subckts = EXPRList{SubcktNode}()
    id = @lift take_node(ps)
    while kind(nt(ps)) == DOT
        dot = @lift take(ps, DOT)
        push!(subckts, EXPR(SubcktNode(id, dot)))
        id = @lift take_node(ps)
    end
    return EXPR(SNode(subckts, id))
end

function take_node(ps)
    if kind(nt(ps)) == NUMBER
        return @lift take_literal(ps)
    elseif is_ident(kind(nt(ps)))
        return @lift take_identifier(ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function parse_global(ps)
    kw = @lift take_kw(ps, GLOBAL)
    nodes = EXPRList{SNode}()
    while !eol(ps)
        push!(nodes, (@lift parse_node(ps)))
    end
    nl = @lift accept_newline(ps)
    return EXPR(Global(kw, nodes, nl))
end

function parse_other(ps)
    name = take_identifier(ps)
    if is_analysis(kind(nt(ps)))
        return @lift parse_analysis(ps, name)
    end
    @case kind(nt(ps)) begin
        LPAREN => @lift parse_instance(ps, name) 
        ALTERGROUP => @lift parse_altergroup(ps, name)
        ALTER => @lift parse_alter(ps, name)
        CHECK => @lift parse_check(ps, name)
        CHECKLIMIT => @lift parse_checklimit(ps, name)
        INFO => @lift parse_info(ps, name)
        OPTIONS => @lift parse_options(ps, name)
        SET => @lift parse_set(ps, name)
        SHELL => @lift parse_shell(ps, name)
        PARAMTEST => @lift parse_paramtest(ps, name)
        _ => error!(ps, UnexpectedToken)
    end
end

function parse_save_signal(ps)
    signalname = nothing
    if kind(nt(ps)) != COLON
        signalname = @lift parse_node(ps)
    end
    modifier = nothing
    if kind(nt(ps)) == COLON
        col = @lift take(ps, COLON)
        if is_save_kw(kind(nt(ps)))
            mod = @lift take_kw(ps)
        elseif is_number(kind(nt(ps)))
            mod = @lift take_literal(ps)
        elseif is_ident(kind(nt(ps)))
            mod = @lift take_identifier(ps)
        else
            error!(ps, UnexpectedToken)
        end
        modifier = EXPR(SaveSignalModifier(col, mod))
    end
    return EXPR(SaveSignal(signalname, modifier))
end

function parse_save_list(ps)
    signals = EXPRList{SaveSignal}() # TODO
    while !eol(ps)
        signal = @lift parse_save_signal(ps)
        push!(signals, signal)
    end
    return signals
end

function parse_save(ps)
    kw = @lift take_kw(ps)
    signals = @lift parse_save_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Save(kw, signals, nl))
end


function parse_ic_parameter_list(ps)
    parameters = EXPRList{ICParameter}()
    while !eol(ps)
        p = @lift parse_ic_parameter(ps)
        push!(parameters, p)
    end
    return parameters
end

function parse_ic_parameter(ps)
    name = @lift parse_node(ps)
    eq = @lift accept(ps, EQ)
    val = @lift parse_expression(ps)
    return EXPR(ICParameter(name, eq, val))
end

function parse_ic(ps)
    kw = @lift take_kw(ps, IC)
    parameters = @lift parse_ic_parameter_list(ps)
    nl = @lift take(ps, NEWLINE)
    return EXPR(Ic(kw, parameters, nl))
end

function parse_nodeset(ps)
    kw = @lift take_kw(ps, NODESET)
    parameters = @lift parse_parameter_list(ps)
    nl = @lift take(ps, NEWLINE)
    return EXPR(NodeSet(kw, parameters, nl))
end



function parse_altergroup(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, ALTERGROUP)
    lbrace = @lift accept(ps, LBRACE)
    nl1 = @lift accept_newline(ps)
    exprs = EXPRList{Any}()
    while kind(nt(ps)) != RBRACE
        push!(exprs, (@lift parse_spectrenetlist_source(ps)))
    end
    rbrace = @lift accept(ps, RBRACE)
    nl2 = @lift accept_newline(ps)
    return EXPR(AlterGroup(name, kw, lbrace, nl1, exprs, rbrace, nl2))
end

function parse_alter(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, ALTER)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Alter(name, kw, params, nl))
end


function parse_check(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, CHECK)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Check(name, kw, params, nl))
end

function parse_checklimit(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, CHECKLIMIT)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(CheckLimit(name, kw, params, nl))
end

function parse_info(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, INFO)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Info(name, kw, params, nl))
end

function parse_options(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, OPTIONS)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Options(name, kw, params, nl))
end

function parse_set(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, SET)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Set(name, kw, params, nl))
end

function parse_shell(ps, name)
    name = @lift name
    kw = @lift accept_kw(ps, SHELL)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Shell(name, kw, params, nl))
end



function parse_analysis(ps, name, nodelist=nothing)
    name = @lift name
    nodelist = @lift nodelist
    kw = @lift accept_kw(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Analysis(name, nodelist, kw, params, nl))
end

function parse_instance(ps, name)
    name = @lift name
    lparen = @lift accept(ps, LPAREN)
    nodes = @lift parse_nodes(ps)
    rparen = @lift accept(ps, RPAREN)
    nodelist = EXPR(SNodeList(lparen, nodes, rparen))
    if is_analysis(kind(nt(ps)))
        return @lift parse_analysis(ps, name, nodelist)
    end
    master = @lift take_identifier(ps)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Instance(name, nodelist, master, params, nl))
end

function parse_nodes(ps)
    nodes = EXPRList{SNode}()
    while kind(nt(ps)) != RPAREN && !eol(ps)
        id = @lift parse_node(ps)
        push!(nodes, id)
    end
    return nodes
end

function parse_parameter_list(ps)
    parameters = EXPRList{Parameter}()
    while !eol(ps)
        p = @lift parse_parameter(ps)
        push!(parameters, p)
    end
    return parameters
end

eol(ps) = (t = nt(ps); kind(t) == NEWLINE || kind(t) == ENDMARKER)

function parse_parameter(ps)
    name = @lift take_identifier(ps)
    eq = @lift accept(ps, EQ)
    val = @lift parse_expression(ps)
    return EXPR(Parameter(name, eq, val))
end

function parse_parameters(ps)
    kw = @lift accept_kw(ps, PARAMETERS)
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Parameters(kw, params, nl))
end

function parse_expression(ps)
    ex = @lift parse_primary_or_unary(ps)
    if is_operator(kind(nt(ps)))
        op = @lift take_operator(ps)
        ex = @lift parse_binop(ps, ex, op)
    elseif kind(nt(ps)) == CONDITIONAL
        not = @lift take(ps, CONDITIONAL)
        ifcase = @lift parse_expression(ps)
        colon = @lift accept(ps, COLON)
        elsecase = @lift parse_expression(ps)
        ex = EXPR(TernaryExpr(ex, not, ifcase, colon, elsecase))
    end
    return ex
end


function parse_comma_list!(parse_item, ps, list)
    comma = nothing
    while true
        ref = @lift parse_item(ps)
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
        @lift parse_comma_list!(parse_expression, ps, args)
    end
    return EXPR(FunctionCall(name, lparen, args, (@lift accept(ps, RPAREN))))
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
            rhs = @lift parse_binop(ps, rhs, (@lift take_operator(ps)), op)
            ex = EXPR(BinaryExpression(ex, op, rhs))
            is_operator(kind(nt(ps))) || return ex
            op = @lift take_operator(ps)
            continue
        end
    end
    ret = EXPR(BinaryExpression(ex, op, rhs))
    return ret
end


function parse_primary(ps)
    if is_number(kind(nt(ps)))
        return @lift take_literal(ps)
    elseif is_literal(kind(nt(ps)))
        return @lift take_literal(ps)
    elseif is_builtin_const(kind(nt(ps)))
        return @lift take_builtin_const(ps)
    elseif is_ident(kind(nt(ps))) || is_builtin_func(kind(nt(ps)))
        if is_builtin_func(kind(nt(ps)))
            id = take_builtin_func(ps)
        else
            id = take_identifier(ps)
        end
        if kind(nt(ps)) == LPAREN
            return @lift parse_function_call(ps, id)
        else
            return id
        end
    elseif kind(nt(ps)) == STRING
        return @lift take_string(ps)
    elseif kind(nt(ps)) == LSQUARE
        return @lift parse_array(ps)
    elseif is_kw(kind(nt(ps)))
        return @lift take_kw(ps)
    elseif kind(nt(ps)) == LPAREN
        return @lift parse_paren(ps)
    end
    if kind(nt(ps)) in (RPAREN, RBRACE, RSQUARE, COMMA, SEMICOLON, BACKTICK, EQ, LATTR, RATTR, ERROR, COLON, ENDMARKER) || is_kw(kind(nt(ps))) || is_operator(kind(nt(ps)))
        return error!(ps, UnexpectedToken)
    end
    error("internal error: unreachable $(kind(nt(ps)))")
end

function parse_paren(ps)
    lparen = @lift take(ps, LPAREN)
    e = @lift parse_expression(ps)
    rparen = @lift accept(ps, RPAREN)
    return EXPR(Parens(lparen, e, rparen))
end


function parse_array(ps)
    lbrace = @lift take(ps, LSQUARE)
    items = EXPRList{Any}()
    while kind(nt(ps)) !== RSQUARE
        # > When expressions are used within vectors, anything other than constants, parameters,
        # or unary expressions (unary +, unary -) must be surrounded by parentheses
        if kind(nt(ps)) == LPAREN
            v = @lift parse_paren(ps)
        elseif is_unary_operator(kind(nt(ps)))
            v = @lift parse_unary_op(ps)
        elseif is_ident(kind(nt(ps)))
            v = @lift take_identifier(ps)
        elseif is_literal(kind(nt(ps)))
            v = @lift take_literal(ps)
        else
            return error!(ps, UnexpectedToken)
        end
        push!(items, v)
    end
    rbrace = @lift take(ps, RSQUARE)
    return EXPR(SpectreArray(lbrace, items, rbrace))
end

function parse_include(ps)
    kw = @lift take_kw(ps, INCLUDE)
    str = @lift take_string(ps)
    section = nothing
    if kind(nt(ps)) == SECTION
        section = @lift parse_include_section(ps)
    end
    nl = @lift accept_newline(ps)
    return EXPR(Include(kw, str, section, nl))
end

function parse_ahdl_include(ps)
    kw = @lift take_kw(ps, AHDL_INCLUDE)
    str = @lift take_string(ps)
    nl = @lift accept_newline(ps)
    return EXPR(AHDLInclude(kw, str, nl))
end

function parse_include_section(ps)
    kw_sec = @lift take_kw(ps, SECTION)
    eq = @lift take(ps, EQ)
    sec = @lift take_identifier(ps)
    return EXPR(IncludeSection(kw_sec, eq, sec))
end



function parse_simulator(ps)
    kw = @lift take_kw(ps, SIMULATOR)
    langkw = @lift take_kw(ps, LANG)
    eq = @lift take(ps, EQ)
    if kind(nt(ps)) == SPICE
        ps.lang_swapped=true
    end
    lang = @lift take_kw(ps, (SPECTRE, SPICE))
    params = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Simulator(kw, langkw, eq, lang, params, nl))
end


function parse_model(ps)
    kw = @lift take_kw(ps, MODEL)
    name = @lift take_identifier(ps)
    master = @lift take_identifier(ps)
    parameters = @lift parse_parameter_list(ps)
    nl = @lift accept_newline(ps)
    return EXPR(Model(kw, name, master, parameters, nl))
end

function take_kw(ps)
    kwkind = kind(nt(ps))
    if is_kw(kwkind)
        return EXPR!(Keyword(kwkind), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_kw(ps, tkind)
    !isa(tkind, Tuple) && (tkind = (tkind,))
    kwkind = kind(nt(ps))
    if is_kw(kwkind) && kwkind in tkind
        return EXPR!(Keyword(kwkind), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function take_identifier(ps)
    if !(is_ident(kind(nt(ps))))
        error!(ps, UnexpectedToken)
    end
    return EXPR!(Identifier(), ps)
end



function take_literal(ps)
    ntkind = kind(nt(ps))
    if is_literal(ntkind)
        return EXPR!(ntkind == NUMBER ? NumberLiteral() : Literal(), ps)
    else
        return error!(ps, UnexpectedToken)
    end
end

function accept_identifier(ps)
    if kind(nt(ps)) == IDENTIFIER
        return @lift take_identifier(ps)
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
    kwkind = kind(nt(ps))
    if is_kw(kwkind) && kwkind in tkind
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

function error!(ps, kind, expected=nothing)
    ps.errored = true
    prev = ps.prevpos
    fw = ps.allpos - prev
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
    elseif opkind in (EQEQ, NOT_EQ, EQEQEQ, NOT_EQEQ)
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
