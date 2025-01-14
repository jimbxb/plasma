%-----------------------------------------------------------------------%
% Plasma typechecking
% vim: ts=4 sw=4 et
%
% Copyright (C) 2016-2021 Plasma Team
% Distributed under the terms of the MIT see ../LICENSE.code
%
% This module typechecks plasma core using a solver over Prolog-like terms.
% Solver variables and constraints are created as follows.
%
% Consider an expression which performs a list cons:
%
% cons(elem, list)
%
% cons is declared as func(t, List(t)) -> List(t)
%
% + Because we use an ANF-like representation associating a type with each
%   variable is almost sufficient, we also associate types with calls.  Each
%   type is represented by a solver variable.  In this example these are:
%   elem, list and the call to cons.  Each of these can have constraints
%   thate describe any type information we already know:
%   elem       = int
%   list       = T0
%   call(cons) = func(T1, list(T1)) -> list(T1) % based on declaration
%   T1         = int % from function application
%   list(T1)   = T0
%
%   We assume that cons's type is fixed and will not be inferred by this
%   invocation of the solver.  Other cases are handled seperately.
%
%   The new type variable, and therefore solver variable, T1, is introduced.
%   T0 is also introduced to stand in for the type of the list.
%
% + The solver can combine these rules, unifing them and finding the unique
%   solution.  Type variables that appear in the signature of the function are
%   allowed to be part of the solution, others are not as that would mean it
%   is ambigiously typed.
%
% Other type variables and constraints are.
%
% + The parameters and return values of the current function.  Including
%   treatment of any type variables.
%
% Propagation is probably the only step required to find the correct types.
% However labeling (search) can also occur.  Type variables in the signature
% must be handled specially, they must not be labeled during search and may
% require extra rules (WIP).
%
%-----------------------------------------------------------------------%
:- module core.type_chk.
%-----------------------------------------------------------------------%

:- interface.

:- import_module io.

:- import_module compile_error.
:- import_module util.log.
:- import_module util.result.

:- pred type_check(log_config::in, errors(compile_error)::out,
    core::in, core::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
:- implementation.

:- import_module cord.
:- import_module map.
:- import_module require.
:- import_module string.

:- import_module context.
:- import_module core.pretty.
:- import_module core.util.
:- import_module util.
:- import_module util.mercury.
:- import_module util.pretty.

:- include_module core.type_chk.solve.
:- import_module core.type_chk.solve.

%-----------------------------------------------------------------------%

type_check(Verbose, Errors, !Core, !IO) :-
    % TODO: Add support for inference, which must be bottom up by SCC.
    process_noerror_scc_funcs(Verbose, typecheck_func, Errors, !Core, !IO).

:- pred typecheck_func(core::in, func_id::in,
    function::in, result_partial(function, compile_error)::out) is det.

typecheck_func(Core, FuncId, Func0, Result) :-
    % Now do the real typechecking.
    build_cp_func(Core, FuncId, Func0, init, Constraints),
    ( if func_get_varmap(Func0, VarmapPrime) then
        Varmap = VarmapPrime
    else
        unexpected($file, $pred, "Couldn't retrive varmap")
    ),
    MaybeMapping = solve(Core, Varmap, func_get_context(Func0), Constraints),
    ( MaybeMapping = ok(Mapping),
        update_types_func(Core, Mapping, Func0, Func),
        Result = ok(Func, init)
    ; MaybeMapping = errors(Errors),
        Result = errors(Errors)
    ).

%-----------------------------------------------------------------------%

:- pred build_cp_func(core::in, func_id::in, function::in,
    problem::in, problem::out) is det.

build_cp_func(Core, FuncId, Func, !Problem) :-
    trace [io(!IO), compile_time(flag("typecheck_solve"))] (
        % TODO: Fix this once we can typecheck SCCs as it might not make
        % sense anymore.
        FuncName = core_lookup_function_name(Core, FuncId),
        format("\nBuilding typechecking problem for %s\n",
            [s(q_name_to_string(FuncName))], !IO)
    ),

    func_get_type_signature(Func, InputTypes, OutputTypes, _),
    ( if func_get_body(Func, _, Inputs, _, Expr) then
        some [!TypeVars, !TypeVarSource] (
            !:TypeVars = init_type_vars,
            Context = func_get_context(Func),

            start_type_var_mapping(!TypeVars),
            % Determine which type variables are free (universally
            % quantified).
            foldl2(set_free_type_vars(Context), OutputTypes, [],
                ParamFreeVarLits0, !TypeVars),
            foldl2(set_free_type_vars(Context), InputTypes,
                ParamFreeVarLits0, ParamFreeVarLits, !TypeVars),
            post_constraint(make_conjunction_from_lits(ParamFreeVarLits),
                !Problem),

            map_foldl3(build_cp_output(Context), OutputTypes, OutputConstrs,
                0, _, !Problem, !TypeVars),
            map_corresponding_foldl2(build_cp_inputs(Context), InputTypes,
                Inputs, InputConstrs, !Problem, !TypeVars),
            post_constraint(make_conjunction(OutputConstrs ++ InputConstrs),
                !Problem),
            end_type_var_mapping(!TypeVars),

            build_cp_expr(Core, Expr, TypesOrVars, !Problem, !TypeVars),
            list.map_foldl(unify_with_output(Context), TypesOrVars,
                Constraints, 0, _),

            _ = !.TypeVars, % TODO: Is this needed?

            post_constraint(make_conjunction(Constraints), !Problem)
        )
    else
        unexpected($module, $pred, "Imported pred")
    ).

:- pred set_free_type_vars(context::in, type_::in,
    list(constraint_literal)::in, list(constraint_literal)::out,
    type_var_map(type_var)::in, type_var_map(type_var)::out) is det.

set_free_type_vars(_, builtin_type(_), !Lits, !TypeVarMap).
set_free_type_vars(Context, type_variable(TypeVar), Lits, [Lit | Lits],
        !TypeVarMap) :-
    maybe_add_free_type_var(Context, TypeVar, Lit, !TypeVarMap).
set_free_type_vars(Context, type_ref(_, Args), !Lits, !TypeVarMap) :-
    foldl2(set_free_type_vars(Context), Args, !Lits, !TypeVarMap).
set_free_type_vars(Context, func_type(Args, Returns, _, _), !Lits,
        !TypeVarMap) :-
    foldl2(set_free_type_vars(Context), Args, !Lits, !TypeVarMap),
    foldl2(set_free_type_vars(Context), Returns, !Lits, !TypeVarMap).

:- pred build_cp_output(context::in, type_::in, constraint::out,
    int::in, int::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det
    <= var_source(P).

build_cp_output(Context, Out, Constraint, !ResNum, !Problem, !TypeVars) :-
    build_cp_type(Context, dont_include_resources, Out, v_output(!.ResNum),
        Constraint, !Problem, !TypeVars),
    !:ResNum = !.ResNum + 1.

:- pred build_cp_inputs(context::in, type_::in, var::in,
    constraint::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det
    <= var_source(P).

build_cp_inputs(Context, Type, Var, Constraint, !Problem, !TypeVars) :-
    build_cp_type(Context, include_resources, Type, v_named(Var), Constraint,
        !Problem, !TypeVars).

:- pred unify_with_output(context::in, type_or_var::in, constraint::out,
    int::in, int::out) is det.

unify_with_output(Context, TypeOrVar, Constraint, !ResNum) :-
    OutputVar = v_output(!.ResNum),
    !:ResNum = !.ResNum + 1,
    ( TypeOrVar = type_(Type),
        Constraint = build_cp_simple_type(Context, Type, OutputVar)
    ; TypeOrVar = var(Var),
        Constraint = make_constraint(cl_var_var(Var, OutputVar, Context))
    ).

    % An expressions type is either known directly (and has no holes), or is
    % the given variable's type.
    %
:- type type_or_var
    --->    type_(simple_type)
    ;       var(svar).

:- type simple_type
    --->    builtin_type(builtin_type)
    ;       type_ref(type_id).

:- pred build_cp_expr(core::in, expr::in, list(type_or_var)::out,
    problem::in, problem::out, type_vars::in, type_vars::out) is det.

build_cp_expr(Core, expr(ExprType, CodeInfo), TypesOrVars, !Problem,
        !TypeVars) :-
    Context = code_info_context(CodeInfo),
    ( ExprType = e_tuple(Exprs),
        map_foldl2(build_cp_expr(Core), Exprs, ExprsTypesOrVars, !Problem,
            !TypeVars),
        TypesOrVars = map(one_item, ExprsTypesOrVars)
    ; ExprType = e_lets(Lets, ExprIn),
        build_cp_expr_lets(Core, Lets, ExprIn, TypesOrVars,
            !Problem, !TypeVars)
    ; ExprType = e_call(Callee, Args, _),
        % Note that we deliberately ignore the resource set on calls here.
        % It is calculated from the callee after type-checking and checked
        % for correctness in a later pass.
        ( Callee = c_plain(FuncId),
            build_cp_expr_call(Core, FuncId, Args, Context,
                TypesOrVars, !Problem, !TypeVars)
        ; Callee = c_ho(HOVar),
            build_cp_expr_ho_call(HOVar, Args, CodeInfo, TypesOrVars,
                !Problem, !TypeVars)
        )
    ; ExprType = e_match(Var, Cases),
        map_foldl2(build_cp_case(Core, Var), Cases, CasesTypesOrVars,
            !Problem, !TypeVars),
        unify_types_or_vars_list(Context, CasesTypesOrVars, TypesOrVars,
            Constraint),
        post_constraint(Constraint, !Problem)
    ; ExprType = e_var(Var),
        TypesOrVars = [var(v_named(Var))]
    ; ExprType = e_constant(Constant),
        build_cp_expr_constant(Core, Context, Constant, TypesOrVars,
            !Problem, !TypeVars)
    ; ExprType = e_construction(CtorIds, Args),
        build_cp_expr_construction(Core, CtorIds, Args, Context, TypesOrVars,
            !Problem, !TypeVars)
    ; ExprType = e_closure(FuncId, Captured),
        build_cp_expr_function(Core, Context, FuncId, Captured, TypesOrVars,
            !Problem, !TypeVars)
    ).

:- pred build_cp_expr_lets(core::in,
    list(expr_let)::in, expr::in, list(type_or_var)::out,
    problem::in, problem::out, type_vars::in, type_vars::out) is det.

build_cp_expr_lets(Core, Lets, ExprIn, TypesOrVars, !Problem, !TypeVars) :-
    foldl2(build_cp_expr_let(Core), Lets, !Problem, !TypeVars),
    build_cp_expr(Core, ExprIn, TypesOrVars, !Problem, !TypeVars).

:- pred build_cp_expr_let(core::in, expr_let::in,
    problem::in, problem::out, type_vars::in, type_vars::out) is det.

build_cp_expr_let(Core, e_let(Vars, Expr), !Problem, !TypeVars) :-
    build_cp_expr(Core, Expr, LetTypesOrVars, !Problem,
        !TypeVars),
    Context = code_info_context(Expr ^ e_info),
    map_corresponding(
        (pred(Var::in, TypeOrVar::in, Con::out) is det :-
            SVar = v_named(Var),
            ( TypeOrVar = var(EVar),
                Con = make_constraint(cl_var_var(SVar, EVar, Context))
            ; TypeOrVar = type_(Type),
                Con = build_cp_simple_type(Context, Type, SVar)
            )
        ), Vars, LetTypesOrVars, Cons),
    post_constraint(make_conjunction(Cons), !Problem).

:- pred build_cp_expr_call(core::in,
    func_id::in, list(var)::in, context::in,
    list(type_or_var)::out, problem::in, problem::out,
    type_vars::in, type_vars::out) is det.

build_cp_expr_call(Core, Callee, Args, Context,
        TypesOrVars, !Problem, !TypeVars) :-
    core_get_function_det(Core, Callee, Function),
    func_get_type_signature(Function, ParameterTypes, ResultTypes, _),
    start_type_var_mapping(!TypeVars),
    map_corresponding_foldl2(unify_param(Context), ParameterTypes, Args,
        ParamsLiterals, !Problem, !TypeVars),
    post_constraint(make_conjunction(ParamsLiterals), !Problem),
    % XXX: need a new type of solver var for ResultSVars, maybe need
    % expression numbers again?
    map_foldl2(unify_or_return_result(Context), ResultTypes,
        TypesOrVars, !Problem, !TypeVars),
    end_type_var_mapping(!TypeVars).

% TODO: We're not carefully handling resources in arguments to higher order
% calls.

:- pred build_cp_expr_ho_call(var::in, list(var)::in, code_info::in,
    list(type_or_var)::out, problem::in, problem::out,
    type_vars::in, type_vars::out) is det.

build_cp_expr_ho_call(HOVar, Args, CodeInfo, TypesOrVars, !Problem,
        !TypeVarSource) :-
    Context = code_info_context(CodeInfo),

    new_variables("ho_arg", length(Args), ArgVars, !Problem),
    ParamsConstraints = map_corresponding(
        (func(A, AV) = cl_var_var(v_named(A), AV, Context)),
        Args, ArgVars),

    % Need the arity.
    ( if code_info_arity(CodeInfo, Arity) then
        new_variables("ho_result", Arity ^ a_num, ResultVars, !Problem)
    else
        util.exception.sorry($file, $pred, Context,
            format("HO call sites either need static type information or " ++
                    "static arity information, we cannot infer both. " ++
                    "at %s",
                [s(context_string(Context))]))
    ),

    % The resource checking code in core.res_chk.m will check that the
    % correct resources are available here.
    HOVarConstraint = [cl_var_func(v_named(HOVar), ArgVars,
        ResultVars, unknown_resources, Context)],
    post_constraint(
        make_conjunction_from_lits(HOVarConstraint ++ ParamsConstraints),
        !Problem),

    TypesOrVars = map(func(V) = var(V), ResultVars).

:- pred build_cp_case(core::in, var::in, expr_case::in, list(type_or_var)::out,
    problem::in, problem::out, type_vars::in, type_vars::out) is det.

build_cp_case(Core, Var, e_case(Pattern, Expr), TypesOrVars, !Problem,
        !TypeVarSource) :-
    Context = code_info_context(Expr ^ e_info),
    build_cp_pattern(Core, Context, Pattern, Var, Constraint,
        !Problem, !TypeVarSource),
    post_constraint(Constraint, !Problem),
    build_cp_expr(Core, Expr, TypesOrVars, !Problem, !TypeVarSource).

:- pred build_cp_pattern(core::in, context::in, expr_pattern::in, var::in,
    constraint::out, P::in, P::out, type_vars::in, type_vars::out) is det
    <= var_source(P).

build_cp_pattern(_, Context, p_num(_), Var, Constraint,
        !Problem, !TypeVarSource) :-
    Constraint = make_constraint(cl_var_builtin(v_named(Var), int, Context)).
build_cp_pattern(_, Context, p_variable(VarA), Var, Constraint,
        !Problem, !TypeVarSource) :-
    Constraint = make_constraint(
        cl_var_var(v_named(VarA), v_named(Var), Context)).
build_cp_pattern(_, _, p_wildcard, _, make_constraint(cl_true),
    !Problem, !TypeVarSource).
build_cp_pattern(Core, Context, p_ctor(CtorIds, Args), Var, Constraint,
        !Problem, !TypeVarSource) :-
    SVar = v_named(Var),
    map_foldl2((pred(C::in, Ds::out,
                P0::in, P::out, TV0::in, TV::out) is det :-
            core_get_constructor_type(Core, C, Type),
            build_cp_ctor_type(Core, C, SVar, Args, Context, Type,
                Ds, P0, P, TV0, TV)
        ), to_sorted_list(CtorIds), Disjuncts, !Problem, !TypeVarSource),
    Constraint = make_disjunction(Disjuncts).

:- pred build_cp_expr_constant(core::in, context::in, const_type::in,
    list(type_or_var)::out, problem ::in, problem::out,
    type_vars::in, type_vars::out) is det.

build_cp_expr_constant(_, Context, c_string(Str), TypesOrVars, !Problem,
        !TypeVars) :-
    ( if count_codepoints(Str) = 1 then
        % This could be a string or a single character.
        new_variable("string_or_codepoint", Var, !Problem),
        post_constraint(make_disjunction([
                make_constraint(cl_var_builtin(Var, string, Context)),
                make_constraint(cl_var_builtin(Var, codepoint, Context))]),
            !Problem),
        TypesOrVars = [var(Var)]
    else
        TypesOrVars = [type_(builtin_type(string))]
    ).
build_cp_expr_constant(_, _, c_number(_), [type_(builtin_type(int))],
        !Problem, !TypeVars).
build_cp_expr_constant(Core, Context, c_func(FuncId), TypesOrVars,
        !Problem, !TypeVars) :-
    build_cp_expr_function(Core, Context, FuncId, [], TypesOrVars, !Problem,
        !TypeVars).
build_cp_expr_constant(_, _, c_ctor(_), _, !Problem, !TypeVars) :-
    % These should be handled by e_construction nodes.  Even those that are
    % constant (for now).
    unexpected($file, $pred, "Constructor").

:- pred build_cp_expr_construction(core::in,
    set(ctor_id)::in, list(var)::in, context::in, list(type_or_var)::out,
    problem::in, problem::out, type_vars::in, type_vars::out) is det.

build_cp_expr_construction(Core, CtorIds, Args, Context, TypesOrVars,
        !Problem, !TypeVars) :-
    new_variable("Constructor expression", SVar, !Problem),
    TypesOrVars = [var(SVar)],

    map_foldl2((pred(C::in, Ds::out,
                P0::in, P::out, TV0::in, TV::out) is det :-
            core_get_constructor_type(Core, C, Type),
            build_cp_ctor_type(Core, C, SVar, Args, Context, Type,
                Ds, P0, P, TV0, TV)
        ), to_sorted_list(CtorIds), Disjuncts, !Problem, !TypeVars),
    post_constraint(make_disjunction(Disjuncts), !Problem).

:- pred build_cp_expr_function(core::in, context::in, func_id::in,
    list(var)::in, list(type_or_var)::out, problem ::in, problem::out,
    type_vars::in, type_vars::out) is det.

build_cp_expr_function(Core, Context, FuncId, Captured, [var(SVar)], !Problem,
        !TypeVars) :-
    new_variable("Function", SVar, !Problem),
    core_get_function_det(Core, FuncId, Func),

    func_get_type_signature(Func, InputTypes, OutputTypes, _),
    start_type_var_mapping(!TypeVars),
    map2_foldl2(build_cp_type_anon("HO Arg", Context), InputTypes,
        InputTypeVars, InputConstraints, !Problem, !TypeVars),
    map2_foldl2(build_cp_type_anon("HO Result", Context), OutputTypes,
        OutputTypeVars, OutputConstraints, !Problem, !TypeVars),

    MaybeCapturedTypes = func_maybe_captured_vars_types(Func),
    ( MaybeCapturedTypes = yes(CapturedTypes),
        map_corresponding_foldl2(build_cp_type(Context, include_resources),
            CapturedTypes, map(func(V) = v_named(V), Captured),
            CapturedConstraints, !Problem, !TypeVars)
    ; MaybeCapturedTypes = no,
        CapturedConstraints = []
    ),

    end_type_var_mapping(!TypeVars),

    func_get_resource_signature(Func, Uses, Observes),
    Resources = resources(Uses, Observes),

    Constraint = make_constraint(cl_var_func(SVar, InputTypeVars,
        OutputTypeVars, Resources, Context)),
    post_constraint(
        make_conjunction([Constraint |
            CapturedConstraints ++ OutputConstraints ++ InputConstraints]),
        !Problem).

%-----------------------------------------------------------------------%

:- pred build_cp_ctor_type(core::in, ctor_id::in, svar::in,
    list(var)::in, context::in, type_id::in, constraint::out,
    P::in, P::out, type_vars::in, type_vars::out) is det <= var_source(P).

build_cp_ctor_type(Core, CtorId, SVar, Args, Context, TypeId, Constraint,
        !Problem, !TypeVars) :-
    core_get_constructor_det(Core, CtorId, Ctor),

    Fields = Ctor ^ c_fields,
    ( if
        length(Fields, N),
        length(Args, N)
    then
        start_type_var_mapping(!TypeVars),

        TypeVarNames = Ctor ^ c_params,
        map_foldl(make_type_var, TypeVarNames, TypeVars, !TypeVars),

        map_corresponding_foldl2(build_cp_ctor_type_arg(Context), Args,
            Fields, ArgConstraints, !Problem, !TypeVars),
        % TODO: record how type variables are mapped and filled in the type
        % constraint below.
        end_type_var_mapping(!TypeVars),

        ResultConstraint = make_constraint(cl_var_usertype(SVar, TypeId,
            TypeVars, Context)),
        Constraint =
            make_conjunction([ResultConstraint | ArgConstraints])
    else
        Constraint = disj([])
    ).

:- pred build_cp_ctor_type_arg(context::in, var::in, type_field::in,
    constraint::out, P::in, P::out,
    type_var_map(type_var)::in, type_var_map(type_var)::out)
    is det <= var_source(P).

build_cp_ctor_type_arg(Context, Arg, Field, Constraint,
        !Problem, !TypeVarMap) :-
    Type = Field ^ tf_type,
    ArgVar = v_named(Arg),
    ( Type = builtin_type(Builtin),
        Constraint = make_constraint(cl_var_builtin(ArgVar, Builtin, Context))
    ; Type = type_ref(TypeId, Args),
        new_variables("Ctor arg", length(Args), ArgsVars, !Problem),
        % TODO: Handle type variables nested within deeper type expressions.
        map_corresponding_foldl2(build_cp_type(Context, dont_include_resources),
            Args, ArgsVars, ArgConstraints, !Problem, !TypeVarMap),
        HeadConstraint = make_constraint(cl_var_usertype(ArgVar, TypeId,
            ArgsVars, Context)),
        Constraint = make_conjunction([HeadConstraint | ArgConstraints])
    ; Type = func_type(_, _, _, _),
        util.exception.sorry($file, $pred, Context, "Function type")
    ; Type = type_variable(TypeVarStr),
        TypeVar = lookup_type_var(!.TypeVarMap, TypeVarStr),
        Constraint = make_constraint(cl_var_var(ArgVar, TypeVar, Context))
    ).

%-----------------------------------------------------------------------%

:- pred unify_types_or_vars_list(context::in, list(list(type_or_var))::in,
    list(type_or_var)::out, constraint::out) is det.

unify_types_or_vars_list(_, [], _, _) :-
    unexpected($file, $pred, "No cases").
unify_types_or_vars_list(Context, [ToVsHead | ToVsTail], ToVs,
        make_conjunction(Constraints)) :-
    unify_types_or_vars_list(Context, ToVsHead, ToVsTail, ToVs, Constraints).

:- pred unify_types_or_vars_list(context::in, list(type_or_var)::in,
    list(list(type_or_var))::in, list(type_or_var)::out,
    list(constraint)::out) is det.

unify_types_or_vars_list(_, ToVs, [], ToVs, []).
unify_types_or_vars_list(Context, ToVsA, [ToVsB | ToVsTail], ToVs,
        CHeads ++ CTail) :-
    map2_corresponding(unify_type_or_var(Context), ToVsA, ToVsB, ToVs0,
        CHeads),
    unify_types_or_vars_list(Context, ToVs0, ToVsTail, ToVs, CTail).

:- pred unify_type_or_var(context::in, type_or_var::in, type_or_var::in,
    type_or_var::out, constraint::out) is det.

unify_type_or_var(Context, type_(TypeA), ToVB, ToV, Constraint) :-
    ( ToVB = type_(TypeB),
        ( if TypeA = TypeB then
            ToV = type_(TypeA)
        else
            compile_error($file, $pred, "Compilation error, cannot unify types")
        ),
        Constraint = make_constraint(cl_true)
    ;
        ToVB = var(Var),
        % It's important to return the var, rather than the type, so that
        % all the types end up getting unified with one-another by the
        % solver.
        ToV = var(Var),
        Constraint = build_cp_simple_type(Context, TypeA, Var)
    ).
unify_type_or_var(Context, var(VarA), ToVB, ToV, Constraint) :-
    ( ToVB = type_(Type),
        unify_type_or_var(Context, type_(Type), var(VarA), ToV, Constraint)
    ; ToVB = var(VarB),
        ToV = var(VarA),
        ( if VarA = VarB then
            Constraint = make_constraint(cl_true)
        else
            Constraint = make_constraint(cl_var_var(VarA, VarB, Context))
        )
    ).

:- pred unify_param(context::in, type_::in, var::in,
    constraint::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det
    <= var_source(P).

unify_param(Context, PType, ArgVar, Constraint, !Problem, !TypeVars) :-
    % XXX: Should be using TVarmap to handle type variables correctly.
    build_cp_type(Context, dont_include_resources, PType, v_named(ArgVar),
        Constraint, !Problem, !TypeVars).

:- pred unify_or_return_result(context::in, type_::in,
    type_or_var::out, problem::in, problem::out,
    type_var_map(string)::in, type_var_map(string)::out) is det.

unify_or_return_result(_, builtin_type(Builtin),
        type_(builtin_type(Builtin)), !Problem, !TypeVars).
unify_or_return_result(_, type_variable(TypeVar),
        var(SVar), !Problem, !TypeVars) :-
    get_or_make_type_var(TypeVar, SVar, !TypeVars).
unify_or_return_result(Context, Type, var(SVar), !Problem, !TypeVars) :-
    ( Type = type_ref(_, _)
    ; Type = func_type(_, _, _, _)
    ),
    new_variable("?", SVar, !Problem),
    % TODO: Test functions in structures as returns.
    build_cp_type(Context, include_resources, Type, SVar, Constraint,
        !Problem, !TypeVars),
    post_constraint(Constraint, !Problem).

%-----------------------------------------------------------------------%

:- type include_resources
    --->    include_resources
    ;       dont_include_resources.

:- pred build_cp_type(context::in, include_resources::in,
    type_::in, svar::in, constraint::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det <= var_source(P).

build_cp_type(Context, _, builtin_type(Builtin), Var,
    make_constraint(cl_var_builtin(Var, Builtin, Context)),
        !Problem, !TypeVarMap).
build_cp_type(Context, _, type_variable(TypeVarStr), Var, Constraint,
        !Problem, !TypeVarMap) :-
    get_or_make_type_var(TypeVarStr, TypeVar, !TypeVarMap),
    Constraint = make_constraint(cl_var_var(Var, TypeVar, Context)).
build_cp_type(Context, IncludeRes, type_ref(TypeId, Args), Var,
        make_conjunction([Constraint | ArgConstraints]),
        !Problem, !TypeVarMap) :-
    build_cp_type_args(Context, IncludeRes, Args, ArgVars, ArgConstraints,
        !Problem, !TypeVarMap),
    Constraint = make_constraint(cl_var_usertype(Var, TypeId, ArgVars,
        Context)).
build_cp_type(Context, IncludeRes,
        func_type(Inputs, Outputs, Uses, Observes), Var,
        make_conjunction(Conjunctions), !Problem, !TypeVarMap) :-
    build_cp_type_args(Context, IncludeRes, Inputs, InputVars,
        InputConstraints, !Problem, !TypeVarMap),
    build_cp_type_args(Context, IncludeRes, Outputs, OutputVars,
        OutputConstraints, !Problem, !TypeVarMap),
    ( IncludeRes = include_resources,
        Resources = resources(Uses, Observes)
    ; IncludeRes = dont_include_resources,
        Resources = unknown_resources
    ),
    Constraint = make_constraint(cl_var_func(Var, InputVars, OutputVars,
        Resources, Context)),
    Conjunctions = [Constraint | InputConstraints ++ OutputConstraints].

:- pred build_cp_type_args(context::in, include_resources::in, list(type_)::in,
    list(svar)::out, list(constraint)::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det
    <= var_source(P).

build_cp_type_args(Context, IncludeRes, Args, Vars, Constraints, !Problem,
        !TypeVarMap) :-
    NumArgs = length(Args),
    new_variables("?", NumArgs, Vars, !Problem),
    map_corresponding_foldl2(build_cp_type(Context, IncludeRes),
        Args, Vars, Constraints, !Problem, !TypeVarMap).

:- func build_cp_simple_type(context, simple_type, svar) = constraint.

build_cp_simple_type(Context, builtin_type(Builtin), Var) =
    make_constraint(cl_var_builtin(Var, Builtin, Context)).
build_cp_simple_type(Context, type_ref(TypeId), Var) =
    make_constraint(cl_var_usertype(Var, TypeId, [], Context)).

:- pred build_cp_type_anon(string::in, context::in, type_::in,
    svar::out, constraint::out, P::in, P::out,
    type_var_map(string)::in, type_var_map(string)::out) is det
    <= var_source(P).

build_cp_type_anon(Comment, Context, Type, Var, Constraint, !Problem,
        !TypeVars) :-
    new_variable(Comment, Var, !Problem),
    build_cp_type(Context, include_resources, Type, Var, Constraint,
        !Problem, !TypeVars).

%-----------------------------------------------------------------------%

:- pred update_types_func(core::in, map(svar_user, type_)::in,
    function::in, function::out) is det.

update_types_func(Core, TypeMap, !Func) :-
    some [!Expr] (
        ( if func_get_body(!.Func, Varmap, Inputs, Captured, !:Expr) then
            func_get_type_signature(!.Func, _, OutputTypes, _),
            update_types_expr(Core, Varmap, TypeMap, at_root_expr,
                OutputTypes, _Types, !Expr),

            map.foldl(svar_type_to_var_type_map, TypeMap, map.init, VarTypes),
            func_set_body(Varmap, Inputs, Captured, !.Expr, !Func),
            func_set_vartypes(VarTypes, !Func),
            func_set_captured_vars_types(
                map(map.lookup(VarTypes), Captured), !Func)
        else
            unexpected($file, $pred, "imported pred")
        )
    ).

:- pred svar_type_to_var_type_map(svar_user::in, type_::in,
    map(var, type_)::in, map(var, type_)::out) is det.

svar_type_to_var_type_map(vu_named(Var), Type, !Map) :-
    det_insert(Var, Type, !Map).
svar_type_to_var_type_map(vu_output(_), _, !Map).

:- type at_root_expr
            % The expressions type comes from the function outputs, and
            % must have any resources ignored.
    --->    at_root_expr
    ;       at_other_expr.

:- pred update_types_expr(core::in, varmap::in, map(svar_user, type_)::in,
    at_root_expr::in, list(type_)::in, list(type_)::out, expr::in, expr::out)
    is det.

update_types_expr(Core, Varmap, TypeMap, AtRoot, !Types, !Expr) :-
    !.Expr = expr(ExprType0, CodeInfo0),
    ( ExprType0 = e_tuple(Exprs0),
        map2_corresponding((pred(T0::in, E0::in, T::out, E::out) is det :-
                update_types_expr(Core, Varmap, TypeMap, AtRoot, T0, T,
                    E0, E)
            ),
            map(func(T) = [T], !.Types), Exprs0, Types0, Exprs),
        !:Types = map(one_item, Types0),
        ExprType = e_tuple(Exprs)
    ; ExprType0 = e_lets(Lets0, ExprIn0),
        map(update_types_let(Core, Varmap, TypeMap), Lets0, Lets),
        update_types_expr(Core, Varmap, TypeMap, AtRoot, !Types,
            ExprIn0, ExprIn),
        ExprType = e_lets(Lets, ExprIn)
    ; ExprType0 = e_call(Callee, Args, _),
        ( Callee = c_plain(FuncId),
            core_get_function_det(Core, FuncId, Func),
            func_get_resource_signature(Func, Uses, Observes),
            Resources = resources(Uses, Observes)
        ; Callee = c_ho(HOVar),
            lookup(TypeMap, vu_named(HOVar), HOType),
            ( if HOType = func_type(_, _, Uses, Observes) then
                Resources = resources(Uses, Observes)
            else
                unexpected($file, $pred, "Call to non-function")
            )
        ),
        ExprType = e_call(Callee, Args, Resources)
    ; ExprType0 = e_match(Var, Cases0),
        % Get the set of e ctor ids for the patterns used here.
        lookup(TypeMap, vu_named(Var), VarType),
        MaybeTypeCtors = map_maybe(list_to_set, type_get_ctors(Core, VarType)),

        map2((pred(C0::in, C::out, T::out) is det :-
                update_types_case(Core, Varmap, TypeMap, AtRoot, MaybeTypeCtors,
                    !.Types, T, C0, C)
            ), Cases0, Cases, Types0),
        ( if
            Types0 = [TypesP | _],
            all_same(Types0)
        then
            !:Types = TypesP
        else
            unexpected($file, $pred, "Mismatching types from match arms")
        ),
        ExprType = e_match(Var, Cases)
    ; ExprType0 = e_var(Var),
        ExprType = ExprType0,
        lookup(TypeMap, vu_named(Var), Type),
        ( if
            !.Types = [TestType],
            require_complete_switch [AtRoot]
            ( AtRoot = at_other_expr,
                TestType \= Type
            ; AtRoot = at_root_expr,
                \+ types_equal_except_resources(TestType, Type)
            )
        then
            Pretties = [p_str("Types do not match for var: "),
                var_pretty(Varmap, Var),
                p_expr([p_str("passed in: "),
                    type_pretty(Core, TestType)]),
                p_expr([p_str("typechecker: "),
                    type_pretty(Core, Type)])],
            unexpected($file, $pred,
                append_list(list(pretty(default_options, 0, Pretties))))
        else
            true
        ),
        !:Types = [Type]
    ; ExprType0 = e_constant(Const),
        ExprType = ExprType0,
        ConstType = const_type(Core, Const),
        % The type inference can't propage resource usage, we need to do that
        % for higher-order values here.  It'll then be checked in the
        % resource checking pass.
        % TODO: If it's stored in a structure rather than returned probably
        % doesn't work?
        ( if
            !.Types = [func_type(Inputs, Outputs, _, _)],
            ConstType = func_type(_, _, Use, Observe)
        then
            !:Types = [func_type(Inputs, Outputs, Use, Observe)]
        else
            true
        )
    ; ExprType0 = e_construction(Ctors0, Args),
        ( if !.Types = [CtorType] then
            MaybeTypeCtors = type_get_ctors(Core, CtorType),
            ( MaybeTypeCtors = yes(TypeCtors0),
                TypeCtors = list_to_set(TypeCtors0),
                Ctors = Ctors0 `intersect` TypeCtors,
                ( if count(Ctors) = 1 then
                    true
                else
                    unexpected($file, $pred, "matching ctors != 1")
                ),
                ExprType = e_construction(Ctors, Args)
            ; MaybeTypeCtors = no,
                unexpected($file, $pred,
                    "Construction of a type that should use e_constant " ++
                    "or is abstract")
            )
        else
            unexpected($file, $pred, "Bad arity")
        )
    ; ExprType0 = e_closure(_, _),
        ExprType = ExprType0
    ),
    code_info_set_types(!.Types, CodeInfo0, CodeInfo),
    !:Expr = expr(ExprType, CodeInfo).

:- pred update_types_let(core::in, varmap::in, map(svar_user, type_)::in,
    expr_let::in, expr_let::out) is det.

update_types_let(Core, Varmap, TypeMap, e_let(Vars, Expr0),
        e_let(Vars, Expr)) :-
    map((pred(V::in, T::out) is det :-
            lookup(TypeMap, vu_named(V), T)
        ), Vars, TypesLet),
    update_types_expr(Core, Varmap, TypeMap, at_other_expr, TypesLet, _,
        Expr0, Expr).

:- pred update_types_case(core::in, varmap::in, map(svar_user, type_)::in,
    at_root_expr::in, maybe(set(ctor_id))::in,
    list(type_)::in, list(type_)::out, expr_case::in, expr_case::out) is det.

update_types_case(Core, Varmap, TypeMap, AtRoot, MaybePossibleCtors, !Types,
        e_case(Pat0, Expr0), e_case(Pat, Expr)) :-
    ( MaybePossibleCtors = yes(PossibleCtors),
        update_ctors_pattern(PossibleCtors, Pat0, Pat)
    ; MaybePossibleCtors = no,
        % Patterns for these types don't need updating, they don't use
        % constructor IDs.
        Pat = Pat0
    ),
    update_types_expr(Core, Varmap, TypeMap, AtRoot, !Types, Expr0, Expr).

:- pred update_ctors_pattern(set(ctor_id)::in,
    expr_pattern::in, expr_pattern::out) is det.

update_ctors_pattern(_, P@p_num(_), P).
update_ctors_pattern(_, P@p_variable(_), P).
update_ctors_pattern(_, p_wildcard, p_wildcard).
update_ctors_pattern(PosCtors, p_ctor(Ctors0, Args), p_ctor(Ctors, Args)) :-
    Ctors = Ctors0 `intersect` PosCtors,
    ( if count(Ctors) = 1 then
        true
    else
        unexpected($file, $pred, "matching ctors != 1")
    ).

%-----------------------------------------------------------------------%

:- func const_type(core, const_type) = type_.

const_type(_,    c_string(_))    = builtin_type(string).
const_type(_,    c_number(_))    = builtin_type(int).
const_type(_,    c_ctor(_))      =
    util.exception.sorry($file, $pred, "Bare constructor").
const_type(Core, c_func(FuncId)) = func_type(Inputs, Outputs, Uses, Observes) :-
    core_get_function_det(Core, FuncId, Func),
    func_get_type_signature(Func, Inputs, Outputs, _),
    func_get_resource_signature(Func, Uses, Observes).

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
