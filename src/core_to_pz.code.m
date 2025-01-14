%-----------------------------------------------------------------------%
% vim: ts=4 sw=4 et
%-----------------------------------------------------------------------%
:- module core_to_pz.code.
%
% Copyright (C) 2015-2021 Plasma Team
% Distributed under the terms of the MIT License see ../LICENSE.code
%
% Plasma core to pz conversion - code generation.
%
%-----------------------------------------------------------------------%
:- interface.

:- import_module builtins.
:- import_module core.
:- import_module core_to_pz.locn.
:- import_module pz.

%-----------------------------------------------------------------------%

:- pred gen_func(compile_options::in, core::in, val_locn_map_static::in,
    pz_builtin_ids::in, map(string, pzd_id)::in,
    type_tag_map::in, constructor_data_map::in,
    pzs_id::in, pair(func_id, function)::in, pz::in, pz::out) is det.

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
:- implementation.

:- import_module assoc_list.
:- import_module char.
:- import_module cord.
:- import_module int.
:- import_module int32.
:- import_module pair.
:- import_module maybe.
:- import_module string.
:- import_module set.
:- import_module uint8.
:- import_module uint32.

:- import_module context.
:- import_module core.code.
:- import_module core.pretty.
:- import_module core_to_pz.closure.
:- import_module util.
:- import_module util.exception.
:- import_module util.mercury.

%-----------------------------------------------------------------------%

gen_func(CompileOpts, Core, LocnMap, BuiltinProcs, FilenameDataMap,
        TypeTagInfo, TypeCtorTagInfo, ModEnvStructId, FuncId - Func, !PZ) :-
    Symbol = func_get_name(Func),

    func_get_type_signature(Func, Input0, Output0, _),
    Input = map(type_to_pz_width, Input0),
    Output = map(type_to_pz_width, Output0),
    Signature = pz_signature(Input, Output),

    ( if
        func_get_body(Func, Varmap, Inputs, Captured, BodyExpr),
        func_get_vartypes(Func, Vartypes)
    then
        % This can eventually be replaced by something smarter that
        % actually re-orders code as a compiler phase, for now this is
        % good enough to get some reasonble codegen.
        find_oneuse_vars(BodyExpr, set.init, _ZeroUse, set.init, OneUse),

        some [!LocnMap] (
            !:LocnMap = LocnMap,
            StructMap = pz_get_struct_names_map(!.PZ),
            ( Captured = [],
                IsClosure = not_closure
            ; Captured = [_ | _],
                IsClosure = is_closure
            ),
            CGInfo = code_gen_info(CompileOpts, Core, BuiltinProcs,
                TypeTagInfo, TypeCtorTagInfo, FuncId, Vartypes, Varmap,
                IsClosure, OneUse, ModEnvStructId, StructMap,
                FilenameDataMap),
            vl_start_var_binding(!LocnMap),
            ( IsClosure = not_closure
            ; IsClosure = is_closure,
                EnvStructId = vl_lookup_closure(!.LocnMap, FuncId),
                vl_setup_closure(EnvStructId, field_num_first, !LocnMap),
                foldl2(set_captured_var_locn(CGInfo, EnvStructId), Captured,
                    !LocnMap, field_num_next(field_num_first), _)
            ),
            gen_proc_body(CGInfo, !.LocnMap, Inputs, BodyExpr, Blocks)
        ),
        ProcId = vls_lookup_proc_id(LocnMap, FuncId),
        Proc = pz_proc(Symbol, Signature, yes(Blocks)),
        pz_add_proc(ProcId, Proc, !PZ)
    else
        % Imports were placed into the PZ structure earlier.
        true
    ).

:- pred gen_proc_body(code_gen_info::in, val_locn_map::in, list(var)::in,
    expr::in, list(pz_block)::out) is det.

gen_proc_body(CGInfo, !.LocnMap, Params, Expr, Blocks) :-
    Varmap = CGInfo ^ cgi_varmap,
    some [!Blocks] (
        !:Blocks = pz_blocks(0u32, map.init),
        alloc_block(EntryBlockId, !Blocks),

        initial_bind_map(Params, 0, Varmap, ParamDepthComments, !LocnMap),

        Depth = length(Params),
        gen_instrs(CGInfo, Expr, Depth, !.LocnMap, cont_return, ExprInstrs,
            !Blocks),

        % Finish block.
        create_block(EntryBlockId, ParamDepthComments ++ ExprInstrs, !Blocks),
        Blocks = values(to_sorted_assoc_list(!.Blocks ^ pzb_blocks))
    ).

:- pred set_captured_var_locn(code_gen_info::in, pzs_id::in, var::in,
    val_locn_map::in, val_locn_map::out, field_num::in, field_num::out) is det.

set_captured_var_locn(CGInfo, EnvStructId, Var, !Map, !FieldNum) :-
    lookup(CGInfo ^ cgi_type_map, Var, Type),
    Width = type_to_pz_width(Type),
    vl_set_var_env(Var, EnvStructId, !.FieldNum, Width, !Map),
    !:FieldNum = field_num_next(!.FieldNum).

%-----------------------------------------------------------------------%

    % fixup_stack(BottomItems, Items)
    %
    % Fixup the stack,  This is used to remove some BottomItems from benieth
    % Items on the stack, so that the stack is at the correct depth and has
    % only Items on it.  For example fixup_stack(2, 3) will take a stack
    % like:
    %
    %   b1 b2 i1 i2 i3
    %
    % And remove b1 and b2 creating:
    %
    %   i1 i2 i3
    %
:- func fixup_stack(int, int) = cord(pz_instr_obj).

fixup_stack(BottomItems, Items) = Fixup :-
    ( if BottomItems < 0 ; Items < 0 then
        unexpected($file, $pred,
            format("fixup_stack(%d, %d)", [i(BottomItems), i(Items)]))
    else
        Fixup0 = fixup_stack_2(BottomItems, Items),
        ( if is_empty(Fixup0) then
            Fixup = singleton(pzio_comment("no fixup"))
        else
            Fixup = cons(pzio_comment(
                    format("fixup_stack(%d, %d)", [i(BottomItems), i(Items)])),
                map((func(I) = pzio_instr(I)), Fixup0))
        )
    ).

:- func fixup_stack_2(int, int) = cord(pz_instr).

fixup_stack_2(BottomItems, Items) =
    ( if BottomItems = 0 then
        % There are no items underneath the items we want to return.
        init
    else if Items = 0 then
        % There are no items on the top, so we can just drop BottomItems.
        cord.from_list(condense(duplicate(BottomItems, [pzi_drop])))
    else
        cord.from_list([pzi_roll(BottomItems + Items), pzi_drop]) ++
            fixup_stack_2(BottomItems - 1, Items)
    ).

%-----------------------------------------------------------------------%

:- type code_gen_info
    --->    code_gen_info(
                cgi_options             :: compile_options,
                cgi_core                :: core,
                cgi_builtin_ids         :: pz_builtin_ids,
                cgi_type_tags           :: map(type_id, type_tag_info),
                cgi_type_ctor_tags      :: map({type_id, ctor_id},
                                                constructor_data),
                cgi_this_func           :: func_id,
                cgi_type_map            :: map(var, type_),
                cgi_varmap              :: varmap,
                cgi_func_is_closure     :: is_closure,
                cgi_var_one_use         :: set(var),
                cgi_mod_env_struct      :: pzs_id,
                cgi_struct_names        :: map(pzs_id, string),
                cgi_filename_data       :: map(string, pzd_id)
            ).

:- type is_closure
            % The function runs in some environment other than the module's
            % environment.
    --->    is_closure
            % The function runs in the module's environment.
    ;       not_closure.

    % gen_instrs(Info, Expr, Depth, LocnMap, Cont, Instrs, !Blocks).
    %
    % Generate instructions (Instrs) for an expression (Expr) and it's
    % continuation (Cont).  The continuation is important for handling
    % returns, switches and lets.  It represents what to execute after this
    % expression.
    %
:- pred gen_instrs(code_gen_info::in, expr::in, int::in, val_locn_map::in,
    continuation::in, cord(pz_instr_obj)::out, pz_blocks::in, pz_blocks::out)
    is det.

gen_instrs(CGInfo, Expr, Depth, LocnMap, Continuation, CtxtInstrs ++ Instrs,
        !Blocks) :-
    Expr = expr(ExprType, CodeInfo),

    Context = code_info_context(CodeInfo),
    ( if not is_nil_context(Context) then
        FilenameDataId = lookup(CGInfo ^ cgi_filename_data, Context ^ c_file),
        PZContext = pz_context(Context, FilenameDataId)
    else
        PZContext = pz_nil_context
    ),
    CtxtInstrs = singleton(pzio_context(PZContext)),

    ( ExprType = e_call(Callee, Args, _),
        gen_call(CGInfo, Callee, Args, CodeInfo, Depth, LocnMap,
            Continuation, Instrs)
    ;
        ( ExprType = e_var(Var),
            InstrsMain = gen_var_access(CGInfo, LocnMap, Var, Depth)
        ; ExprType = e_constant(Const),
            ( Const = c_number(Num),
                InstrsMain = singleton(pzio_instr(
                    pzi_load_immediate(pzw_fast, im_i32(det_from_int(Num)))))
            ; Const = c_string(String),
                ( if
                    [builtin_type(string)] = code_info_types(CodeInfo)
                then
                    Locn = vl_lookup_str(LocnMap, String),
                    InstrsMain = gen_val_locn_access(CGInfo, Depth, LocnMap,
                        Locn)
                else if
                    [builtin_type(codepoint)] = code_info_types(CodeInfo)
                then
                    % We can use det_from_int because Unicode won't exceed
                    % range.
                    InstrsMain = singleton(pzio_instr(pzi_load_immediate(pzw_32,
                        im_u32(det_from_int(to_int(det_index(String, 0)))))))
                else
                    unexpected($file, $pred,
                        "String literal has invalid type")
                )
            ; Const = c_func(FuncId),
                Locn = vl_lookup_proc(LocnMap, FuncId),
                ( Locn = pl_static_proc(PID),
                    % Make a closure.  TODO: To support closures in
                    % Plasma we'll need to move this into a earlier
                    % stage of the compiler.
                    InstrsMain = from_list([
                        pzio_instr(pzi_get_env),
                        pzio_instr(pzi_make_closure(PID))
                    ])
                ; Locn = pl_other(ValLocn),
                    InstrsMain = gen_val_locn_access(CGInfo, Depth, LocnMap,
                        ValLocn)
                ; Locn = pl_instrs(_, no),
                    % This should have been filtered out and wrapped in a
                    % proc if it appears as a constant.
                    unexpected($file, $pred, "Instructions")
                ; Locn = pl_instrs(_, yes(PID)),
                    InstrsMain = from_list([
                        pzio_instr(pzi_get_env),
                        pzio_instr(pzi_make_closure(PID))
                    ])
                )
            ; Const = c_ctor(_),
                util.exception.sorry($file, $pred, Context,
                    "Type constructor as higher order value")
            )
        ; ExprType = e_construction(CtorIds, Args),
            CtorId = one_item_in_set(CtorIds),
            TypeId = one_item(code_info_types(CodeInfo)),
            gen_instrs_args(CGInfo, LocnMap, Args, ArgsInstrs, Depth, _),
            InstrsMain = ArgsInstrs ++
                gen_construction(CGInfo, TypeId, CtorId)
        ; ExprType = e_closure(FuncId, Captured),
            gen_closure(CGInfo, FuncId, Captured, Depth, LocnMap, InstrsMain)
        ),
        Arity = code_info_arity_det(CodeInfo),
        InstrsCont = gen_continuation(Continuation, Depth, Arity ^ a_num,
            "gen_instrs"),
        Instrs = InstrsMain ++ InstrsCont
    ; ExprType = e_tuple(Exprs),
        gen_tuple(CGInfo, Exprs, Depth, LocnMap, Continuation,
            Instrs, !Blocks)
    ; ExprType = e_lets(Lets, InExpr),
        gen_lets(CGInfo, Lets, InExpr, Depth, LocnMap, Continuation,
            Instrs, !Blocks)
    ; ExprType = e_match(Var, Cases),
        gen_match(CGInfo, Var, Cases, Depth, LocnMap,
            Continuation, Instrs, !Blocks)
    ).

%-----------------------------------------------------------------------%

:- pred gen_call(code_gen_info::in, callee::in, list(var)::in, code_info::in,
    int::in, val_locn_map::in, continuation::in, cord(pz_instr_obj)::out)
    is det.

gen_call(CGInfo, Callee, Args, CodeInfo, Depth, LocnMap, Continuation,
        Instrs) :-
    Core = CGInfo ^ cgi_core,
    Varmap = CGInfo ^ cgi_varmap,
    gen_instrs_args(CGInfo, LocnMap, Args, InstrsArgs, Depth, _),

    ( Callee = c_plain(FuncId),
        core_get_function_det(Core, FuncId, Func),
        Decl = func_call_pretty(Core, Func, Varmap, Args),
        CallComment = singleton(pzio_comment(Decl)),

        Locn = vl_lookup_proc(LocnMap, FuncId),
        ( Locn = pl_instrs(Instrs0, _),
            % The function is implemented with a short sequence of
            % instructions.
            Instrs1 = singleton(pzio_comment("Callee is instructions")) ++
                cord.from_list(map((func(I) = pzio_instr(I)), Instrs0)),
            PrepareStackInstrs = init
        ; Locn = pl_static_proc(PID),
            ( if
                is_closure = CGInfo ^ cgi_func_is_closure,
                FuncId \= CGInfo ^ cgi_this_func
            then
                % We're in a closure, but this plain call needs the
                % environment of the module, so we need a closue call.
                % TODO This causes a memory allocation that could be eleuded
                % if we added an instruction to execute a predicate with a
                % given environment (from the stack) as a closure call.  But
                % rather than add that now first we should Fix Bug #333.
                LookupInstrs = gen_val_locn_access(CGInfo, Depth, LocnMap,
                    vl_lookup_mod_env(LocnMap)),
                InstrsClosure = LookupInstrs ++ singleton(
                    pzio_instr(pzi_make_closure(PID))),
                MbPZCallee = no
            else
                InstrsClosure = init,
                MbPZCallee = yes(pzc_proc_opt(PID))
            ),

            ( if
                can_tailcall(CGInfo, c_plain(FuncId), Continuation)
            then
                % Note that we fixup the stack before making a tailcall
                % because the continuation isn't used.
                PrepareStackInstrs = fixup_stack(Depth, length(Args)),
                ( MbPZCallee = yes(PZCallee),
                    Instr = pzi_tcall(PZCallee)
                ; MbPZCallee = no,
                    Instr = pzi_tcall_ind
                )
            else
                PrepareStackInstrs = init,
                ( MbPZCallee = yes(PZCallee),
                    Instr = pzi_call(PZCallee)
                ; MbPZCallee = no,
                    Instr = pzi_call_ind
                )
            ),
            Instrs1 = InstrsClosure ++ singleton(pzio_instr(Instr))
        ; Locn = pl_other(ValLocn),
            PrepareStackInstrs = init,
            Instrs1 =
                singleton(pzio_comment(
                    "Accessing callee as value location")) ++
                gen_val_locn_access(CGInfo, Depth, LocnMap, ValLocn) ++
                singleton(pzio_instr(pzi_call_ind))
        )
    ; Callee = c_ho(HOVar),
        HOVarName = varmap.get_var_name(Varmap, HOVar),
        map.lookup(CGInfo ^ cgi_type_map, HOVar, HOType),
        ( if
            HOType = func_type(HOTypeArgs, HOTypeReturns, HOUses,
                HOObserves)
        then
            Pretty = type_pretty_func(Core, HOVarName, HOTypeArgs,
                HOTypeReturns, HOUses, HOObserves)
        else
            unexpected($file, $pred,
                "Called variable is not a function type")
        ),
        CallComment = singleton(pzio_comment(Pretty)),
        HOVarDepth = Depth + length(Args),
        Instrs1 = gen_var_access(CGInfo, LocnMap, HOVar, HOVarDepth) ++
            singleton(pzio_instr(pzi_call_ind)),
        PrepareStackInstrs = init
    ),
    InstrsMain = CallComment ++ InstrsArgs ++ PrepareStackInstrs ++ Instrs1,
    Arity = code_info_arity_det(CodeInfo),
    ( if can_tailcall(CGInfo, Callee, Continuation) then
        % We did a tail call so there's no continuation.
        InstrsCont = empty
    else
        InstrsCont = gen_continuation(Continuation, Depth, Arity ^ a_num,
            "gen_instrs")
    ),
    Instrs = InstrsMain ++ InstrsCont.

:- pred can_tailcall(code_gen_info::in, callee::in, continuation::in)
    is semidet.

can_tailcall(CGInfo, Callee, Continuation) :-
    EnableTailcalls = CGInfo ^ cgi_options ^ co_enable_tailcalls,
    EnableTailcalls = enable_tailcalls,
    Core = CGInfo ^ cgi_core,
    Continuation = cont_return,
    Callee = c_plain(FuncId),
    core_get_function_det(Core, FuncId, Func),
    Imported = func_get_imported(Func),
    % XXX: This particular definition of importedness might not be
    % suitable if it diverges from where the actual code is.
    Imported = i_local.

%-----------------------------------------------------------------------%

:- pred gen_tuple(code_gen_info::in, list(expr)::in,
    int::in, val_locn_map::in, continuation::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_tuple(_, [], Depth, _, Continuation, Instrs, !Blocks) :-
    Instrs = gen_continuation(Continuation, Depth, 0, "Empty tuple").
gen_tuple(CGInfo, [Arg], Depth, LocnMap, Continue, Instrs, !Blocks) :-
    gen_instrs(CGInfo, Arg, Depth, LocnMap, Continue, Instrs, !Blocks).
gen_tuple(CGInfo, Args@[_, _ | _], Depth, LocnMap, Continue, Instrs,
        !Blocks) :-
    % LocnMap does not change in a list of arguments because arguments
    % do not affect one-another's environment.

    ( if all [Arg] member(Arg, Args) =>
        Arity = code_info_arity_det(Arg ^ e_info),
        Arity ^ a_num = 1
    then
        gen_tuple_loop(CGInfo, Args, Depth, LocnMap, init, InstrsArgs,
            !Blocks),
        TupleLength = length(Args),
        InstrsContinue = gen_continuation(Continue, Depth, TupleLength,
            "Tuple"),

        Instrs = InstrsArgs ++ InstrsContinue
    else
        unexpected($file, $pred, "Bad expression arity used in argument")
    ).

:- pred gen_tuple_loop(code_gen_info::in, list(expr)::in,
    int::in, val_locn_map::in, cord(pz_instr_obj)::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_tuple_loop(_, [], _, _, !Instrs, !Blocks).
gen_tuple_loop(CGInfo, [Expr | Exprs], Depth, LocnMap, !Instrs,
        !Blocks) :-
    gen_instrs(CGInfo, Expr, Depth, LocnMap, cont_none(Depth), ExprInstrs,
        !Blocks),
    !:Instrs = !.Instrs ++ ExprInstrs,
    gen_tuple_loop(CGInfo, Exprs, Depth+1, LocnMap, !Instrs,
        !Blocks).

%-----------------------------------------------------------------------%

:- pred gen_lets(code_gen_info::in, list(expr_let)::in, expr::in,
    int::in, val_locn_map::in, continuation::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_lets(CGInfo, Lets, InExpr, Depth, LocnMap, Continuation, Instrs,
        !Blocks) :-
    ( Lets = [],
        gen_instrs(CGInfo, InExpr, Depth, LocnMap, Continuation, Instrs,
            !Blocks)
    ; Lets = [L | Ls],
        L = e_let(Vars, LetExpr),

        ( if
            Vars = [Var],
            member(Var, CGInfo ^ cgi_var_one_use),
            no_bang_marker = code_info_bang_marker(LetExpr ^ e_info),
            not expr_has_branch(LetExpr)
        then
            % We can skip generation of this variable and generate it
            % directly when it is needed.
            vl_set_var_expr(Var, LetExpr, LocnMap, NextLocnMap),
            gen_lets(CGInfo, Ls, InExpr, Depth, NextLocnMap, Continuation,
                Instrs, !Blocks)
        else
            % Generate the instructions for the "In" part (the continuation
            % of the "Let" part).
            % Update the LocnMap for the "In" part of the expression.  This
            % records the stack slot that we expect to find each variable.
            Varmap = CGInfo ^ cgi_varmap,
            vl_put_vars(Vars, Depth, Varmap, CommentBinds, LocnMap, InLocnMap),

            % Run the "In" expression.
            LetArity = code_info_arity_det(LetExpr ^ e_info),
            InDepth = Depth + LetArity ^ a_num,
            gen_lets(CGInfo, Ls, InExpr, InDepth, InLocnMap, Continuation,
                InInstrs, !Blocks),
            InContinuation = cont_comment(
                    format("In at depth %d", [i(InDepth)]),
                    cont_instrs(InDepth, CommentBinds ++ InInstrs)),

            % Generate the instructions for the "let" part, using the "in"
            % part as the continuation.
            gen_instrs(CGInfo, LetExpr, Depth, LocnMap, InContinuation,
                Instrs0, !Blocks),
            Instrs = cons(pzio_comment(format("Let at depth %d", [i(Depth)])),
                Instrs0)
        )
    ).

%-----------------------------------------------------------------------%

:- pred gen_match(code_gen_info::in, var::in, list(expr_case)::in,
    int::in, val_locn_map::in, continuation::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_match(CGInfo, Var, Cases, Depth, LocnMap,
        Continuation, Instrs, !Blocks) :-
    % We can assume that the cases are exhaustive, there's no need to
    % generate match-all code.  A transformation on the core
    % representation will ensure this.

    % First, generate the bodies of each case.
    continuation_make_block(Continuation, BranchContinuation, !Blocks),
    list.foldl3(gen_case(CGInfo, Depth+1, LocnMap, BranchContinuation,
            VarType),
        Cases, 1, _, map.init, CaseInstrMap, !Blocks),

    % Determine the type of switch requred.  These are:
    %   Casecading.
    %   Switch on primary tag (plus value or secondary tag)
    %
    % Later there may be more eg: to support efficient string matching.  Or
    % add computed gotos.
    %
    % Nested matches, or multiple patterns per case will need to be added
    % later, what we do WRT switch type will need to be reconsidered.
    %
    lookup(CGInfo ^ cgi_type_map, Var, VarType),
    SwitchType = var_type_switch_type(CGInfo, VarType),

    % Generate the switch, using the bodies generated above.
    BeginComment = pzio_comment(format("Switch at depth %d", [i(Depth)])),
    GetVarInstrs = gen_var_access(CGInfo, LocnMap, Var, Depth),
    ( SwitchType = enum,
        TestsInstrs = gen_test_and_jump_enum(CGInfo, CaseInstrMap,
            VarType, Depth, Cases, 1)
    ; SwitchType = tags(_TypeId, TagInfo),
        gen_test_and_jump_tags(CGInfo, CaseInstrMap, VarType, TagInfo,
            Cases, TestsInstrs, !Blocks)
    ),
    Instrs = cord.singleton(BeginComment) ++ GetVarInstrs ++ TestsInstrs.

:- type switch_type
    --->    enum
    ;       tags(type_id, map(ptag, type_ptag_info)).

:- func var_type_switch_type(code_gen_info, type_) = switch_type.

var_type_switch_type(_, builtin_type(Builtin)) = SwitchType :-
    ( Builtin = int,
        % This is really stupid, but it'll do for now.
        SwitchType = enum
    ; ( Builtin = string
      ; Builtin = codepoint
      ),
        util.exception.sorry($file, $pred,
            "Cannot switch on strings/codepoints")
    ; Builtin = string_pos,
        unexpected($file, $pred, "Cannot switch on string_pos")
    ).
var_type_switch_type(_, type_variable(_)) =
    unexpected($file, $pred, "Switch types must be concrete").
var_type_switch_type(_, func_type(_, _, _, _)) =
    unexpected($file, $pred, "Cannot switch on functions").
var_type_switch_type(CGInfo, type_ref(TypeId, _)) = SwitchType :-
    map.lookup(CGInfo ^ cgi_type_tags, TypeId, TagInfo),
    ( TagInfo = tti_untagged,
        SwitchType = enum
    ; TagInfo = tti_tagged(PTagInfos),
        SwitchType = tags(TypeId, PTagInfos)
    ; TagInfo = tti_abstract,
        unexpected($file, $pred, "Can't switch on abstract type")
    ).

    % The body of each case is placed in a new block.
    %
    % + If the pattern matches then we jump to that block, that block itself
    %   will execute the expression then execute the continuation.
    % + Otherwise fall-through and try the next case.
    %
    % No indexing, jump tables or other optimisations are
    % implemented.
    %
:- pred gen_case(code_gen_info::in, int::in, val_locn_map::in,
    continuation::in, type_::in, expr_case::in, int::in, int::out,
    map(int, pzb_id)::in, map(int, pzb_id)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_case(CGInfo, !.Depth, LocnMap0, Continue, VarType,
        e_case(Pattern, Expr), !CaseNum, !InstrMap, !Blocks) :-
    alloc_block(BlockNum, !Blocks),
    det_insert(!.CaseNum, BlockNum, !InstrMap),
    !:CaseNum = !.CaseNum + 1,

    DepthCommentBeforeDecon = depth_comment_instr(!.Depth),
    % At the start of the new block we place code that will provide any
    % variables bound by the matching pattern.
    gen_deconstruction(CGInfo, Pattern, VarType, LocnMap0, LocnMap, !Depth,
        InstrsDecon),
    % Generate the body of the new block.
    gen_instrs(CGInfo, Expr, !.Depth, LocnMap, Continue, InstrsBranchBody,
        !Blocks),
    InstrsBranch = singleton(DepthCommentBeforeDecon) ++ InstrsDecon ++
        InstrsBranchBody,

    create_block(BlockNum, InstrsBranch, !Blocks).

:- func gen_test_and_jump_enum(code_gen_info, map(int, pzb_id), type_,
    int, list(expr_case), int) = cord(pz_instr_obj).

gen_test_and_jump_enum(_, _, _, _, [], _) = cord.init.
gen_test_and_jump_enum(CGInfo, BlockMap, Type, Depth, [Case | Cases], CaseNum)
        = InstrsCase ++ InstrsCases :-
    e_case(Pattern, _) = Case,
    lookup(BlockMap, CaseNum, BlockNum),
    InstrsCase = gen_case_match_enum(CGInfo, Pattern, Type, BlockNum,
        Depth),
    InstrsCases = gen_test_and_jump_enum(CGInfo, BlockMap, Type, Depth,
        Cases, CaseNum + 1).

    % The variable that we're switching on is on the top of the stack, and
    % we can use it directly.  But we need to put it back when we're done.
    %
:- func gen_case_match_enum(code_gen_info, expr_pattern, type_,
    pzb_id, int) = cord(pz_instr_obj).

gen_case_match_enum(_, p_num(Num), _, BlockNum, Depth) =
    cord.from_list([
        pzio_comment(format("Case for %d", [i(Num)])),
        % Save the switched-on value for the next case.
        pzio_instr(pzi_pick(1)),
        % Compare Num with TOS and jump if equal.
        % TODO: need to actually check the type and use the correct
        % immediate, this works for now because all numbers are 'fast'.
        pzio_instr(pzi_load_immediate(pzw_fast, im_i32(det_from_int(Num)))),
        pzio_instr(pzi_eq(pzw_fast)),
        depth_comment_instr(Depth + 1),
        pzio_instr(pzi_cjmp(BlockNum, pzw_fast))]).
gen_case_match_enum(_, p_variable(_), _, BlockNum, Depth) =
    cord.from_list([
        pzio_comment("Case match all and bind variable"),
        depth_comment_instr(Depth),
        pzio_instr(pzi_jmp(BlockNum))]).
gen_case_match_enum(_, p_wildcard, _, BlockNum, Depth) =
    cord.from_list([
        pzio_comment("Case match wildcard"),
        depth_comment_instr(Depth),
        pzio_instr(pzi_jmp(BlockNum))]).
gen_case_match_enum(CGInfo, p_ctor(CtorIds, _), VarType, BlockNum,
        Depth) = SetupInstrs ++ MatchInstrs ++ JmpInstrs :-
    CtorId = one_item_in_set(CtorIds),
    SetupInstrs = from_list([
        pzio_comment("Case match deconstruction"),
        depth_comment_instr(Depth),
        % Save the switched-on value for the next case.
        pzio_instr(pzi_pick(1))]),
    ( VarType = type_ref(TypeId, _),
        MatchInstrs = gen_match_ctor(CGInfo, TypeId, VarType, CtorId)
    ;
        ( VarType = builtin_type(_)
        ; VarType = type_variable(_)
        ; VarType = func_type(_, _, _, _)
        ),
        unexpected($file, $pred,
            "Deconstructions must be on user types")
    ),
    JmpInstrs = from_list([
        depth_comment_instr(Depth + 1),
        pzio_instr(pzi_cjmp(BlockNum, pzw_fast))]).

:- pred gen_test_and_jump_tags(code_gen_info::in, map(int, pzb_id)::in,
    type_::in, map(ptag, type_ptag_info)::in, list(expr_case)::in,
    cord(pz_instr_obj)::out, pz_blocks::in, pz_blocks::out) is det.

gen_test_and_jump_tags(CGInfo, BlockMap, Type, PTagInfos, Cases, Instrs,
        !Blocks) :-
    % Get the ptag onto the TOS.
    BreakTagId = CGInfo ^ cgi_builtin_ids ^ pbi_break_tag,
    GetPtagInstrs = cord.from_list([
        pzio_comment("Break the tag, leaving the ptag on the TOS"),
        pzio_instr(pzi_pick(1)),
        pzio_instr(pzi_call(pzc_import(BreakTagId)))]),

    % For every primary tag, test it, and jump to the case it maps to,
    % if there is none, jump to the default cease.
    foldl2(gen_test_and_jump_ptag(CGInfo, BlockMap, Cases, Type),
        PTagInfos, GetPtagInstrs, Instrs, !Blocks).

:- pred gen_test_and_jump_ptag(code_gen_info::in, map(int, pzb_id)::in,
    list(expr_case)::in, type_::in, ptag::in, type_ptag_info::in,
    cord(pz_instr_obj)::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_test_and_jump_ptag(CGInfo, BlockMap, Cases, Type, PTag, PTagInfo, !Instrs,
        !Blocks) :-
    Width = type_to_pz_width(Type),
    require(unify(Width, pzw_ptr), "Expected pointer width"),
    alloc_block(Next, !Blocks),
    Instrs = from_list([
        pzio_instr(pzi_pick(1)),
        pzio_instr(pzi_load_immediate(pzw_ptr,
            im_u32(cast_from_int(to_int(PTag))))),
        pzio_instr(pzi_eq(pzw_ptr)),
        pzio_instr(pzi_cjmp(Next, pzw_fast))
    ]),
    ( PTagInfo = tpti_constant(EnumMap),
        UnshiftValueId =
            CGInfo ^ cgi_builtin_ids ^ pbi_unshift_value,
        GetFieldInstrs = from_list([
            pzio_comment("Drop the primary tag,"),
            pzio_instr(pzi_drop),
            pzio_comment("Unshift the tagged value."),
            pzio_instr(pzi_call(pzc_import(UnshiftValueId)))]),
        map_foldl(gen_test_and_jump_ptag_const(BlockMap, Cases),
            to_assoc_list(EnumMap), NextInstrsList, !Blocks),
        NextInstrs = GetFieldInstrs ++ cord_list_to_cord(NextInstrsList),
        create_block(Next, NextInstrs, !Blocks)
    ; PTagInfo = tpti_pointer(CtorId),
        % Drop the the saved copy of the tag and value off the stack.
        % Depending on the code we jump to there we may need to recreate the
        % value.  We could optimise this _a lot_ better.
        DropInstrs = from_list([
            pzio_comment("Drop the tag and value then jump"),
            pzio_instr(pzi_drop),
            pzio_instr(pzi_drop),
            pzio_instr(pzi_jmp(Dest))]),
        create_block(Next, DropInstrs, !Blocks),

        find_matching_case(Cases, 1, CtorId, _MatchParams, _Expr, CaseNum),
        lookup(BlockMap, CaseNum, Dest)
    ; PTagInfo = tpti_pointer_stag(STagMap),
        STagStruct = CGInfo ^ cgi_builtin_ids ^ pbi_stag_struct,
        GetStagInstrs = from_list([
            pzio_comment("Drop the primary tag"),
            pzio_instr(pzi_drop),
            pzio_comment("The pointer is on TOS, get the stag from it"),
            pzio_instr(pzi_load(STagStruct, field_num(1), pzw_fast)),
            pzio_instr(pzi_drop)
        ]),
        map_foldl(gen_test_and_jump_ptag_stag(BlockMap, Cases),
            to_assoc_list(STagMap), SwitchStagInstrs, !Blocks),
        NextInstrs = GetStagInstrs ++ cord_list_to_cord(SwitchStagInstrs),
        create_block(Next, NextInstrs, !Blocks)
    ),
    !:Instrs = !.Instrs ++ Instrs.

:- pred gen_test_and_jump_ptag_const(map(int, pzb_id)::in, list(expr_case)::in,
    pair(word_bits, ctor_id)::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_test_and_jump_ptag_const(BlockMap, Cases, ConstVal - CtorId, Instrs,
        !Blocks) :-
    alloc_block(Drop, !Blocks),

    Instrs = from_list([
        pzio_instr(pzi_pick(1)),
        pzio_instr(pzi_load_immediate(pzw_ptr, im_u32(ConstVal))),
        pzio_instr(pzi_eq(pzw_ptr)),
        pzio_instr(pzi_cjmp(Drop, pzw_fast))
    ]),

    find_matching_case(Cases, 1, CtorId, _MatchParams, _Expr, CaseNum),
    lookup(BlockMap, CaseNum, Dest),
    DropInstrs = from_list([
        pzio_comment("Drop the secondary tag then jump"),
        pzio_instr(pzi_drop),
        pzio_instr(pzi_jmp(Dest))]),
    create_block(Drop, DropInstrs, !Blocks).

:- pred gen_test_and_jump_ptag_stag(map(int, pzb_id)::in, list(expr_case)::in,
    pair(stag, ctor_id)::in, cord(pz_instr_obj)::out,
    pz_blocks::in, pz_blocks::out) is det.

gen_test_and_jump_ptag_stag(BlockMap, Cases, STag - CtorId, Instrs,
        !Blocks) :-
    alloc_block(Drop, !Blocks),

    Instrs = from_list([
        pzio_instr(pzi_pick(1)),
        pzio_instr(pzi_load_immediate(pzw_fast, im_u32(STag))),
        pzio_instr(pzi_eq(pzw_fast)),
        pzio_instr(pzi_cjmp(Drop, pzw_fast))
    ]),

    find_matching_case(Cases, 1, CtorId, _MatchParams, _Expr, CaseNum),
    lookup(BlockMap, CaseNum, Dest),
    DropInstrs = from_list([
        pzio_comment("Drop the value then jump"),
        pzio_instr(pzi_drop),
        pzio_instr(pzi_jmp(Dest))]),
    create_block(Drop, DropInstrs, !Blocks).

:- pred find_matching_case(list(expr_case)::in, int::in, ctor_id::in,
    list(var)::out, expr::out, int::out) is det.

find_matching_case([], _, _, _, _, _) :-
    unexpected($file, $pred, "Case not found").
find_matching_case([Case | Cases], ThisCaseNum, CtorId, Vars, Expr, CaseNum) :-
    Case = e_case(Pattern, Expr0),
    ( Pattern = p_num(_),
        unexpected($file, $pred,
            "Type error: A number can't match a constructor")
    ; Pattern = p_variable(_),
        util.exception.sorry($file, $pred, "How to set vars"),
        Vars = [],
        Expr = Expr0,
        CaseNum = ThisCaseNum
    ; Pattern = p_wildcard,
        Vars = [],
        Expr = Expr0,
        CaseNum = ThisCaseNum
    ; Pattern = p_ctor(ThisCtorIds, ThisVars),
        ThisCtorId = one_item_in_set(ThisCtorIds),
        ( if CtorId = ThisCtorId then
            Vars = ThisVars,
            Expr = Expr0,
            CaseNum = ThisCaseNum
        else
            find_matching_case(Cases, ThisCaseNum + 1, CtorId, Vars, Expr,
                CaseNum)
        )
    ).

    % Generate code that attempts to match a data constructor.  It has the
    % stack usage (ptr - w) the input is a copy of the value to switch on,
    % the output is a boolean suitable for "cjmp".
    %
    % TODO: This could be made a call to a pz procedure.  Making it a call
    % (outline) matches the pz style, letting the interpreter do the
    % inlining.  It may also make separate compilation simpler.
    %
:- func gen_match_ctor(code_gen_info, type_id, type_, ctor_id) =
    cord(pz_instr_obj).

gen_match_ctor(CGInfo, TypeId, Type, CtorId) = Instrs :-
    map.lookup(CGInfo ^ cgi_type_ctor_tags, {TypeId, CtorId}, CtorData),
    TagInfo = CtorData ^ cd_tag_info,
    Width = type_to_pz_width(Type),
    ( TagInfo = ti_constant(PTag, WordBits),
        require(unify(Width, pzw_ptr), "Width must be pointer for constant"),
        ShiftMakeTagId = CGInfo ^ cgi_builtin_ids ^ pbi_shift_make_tag,
        Instrs = from_list([
            % Compare tagged value with TOS and jump if equal.
            pzio_instr(pzi_load_immediate(pzw_ptr, im_u32(WordBits))),
            pzio_instr(pzi_load_immediate(pzw_ptr,
                im_u32(cast_from_int(to_int(PTag))))),
            pzio_instr(pzi_call(pzc_import(ShiftMakeTagId))),
            pzio_instr(pzi_eq(pzw_ptr))])
    ; TagInfo = ti_constant_notag(Word),
        Instrs = from_list([
            % Compare constant value with TOS and jump if equal.
            pzio_instr(pzi_load_immediate(Width, im_u32(Word))),
            pzio_instr(pzi_eq(Width))])
    ; TagInfo = ti_tagged_pointer(PTag, _, MaybeSTag),
        require(unify(Width, pzw_ptr),
            "Width must be pointer for tagged pointer"),
        % TODO: This is currently unused.
        ( MaybeSTag = no,
            BreakTagId = CGInfo ^ cgi_builtin_ids ^ pbi_break_tag,
            % TODO rather than dropping the pointer we should save it and use it
            % for deconstruction later.
            Instrs = from_list([
                pzio_instr(pzi_call(pzc_import(BreakTagId))),
                pzio_instr(pzi_roll(2)),
                pzio_instr(pzi_drop),
                pzio_instr(pzi_load_immediate(pzw_ptr,
                    im_u32(cast_from_int(to_int(PTag))))),
                pzio_instr(pzi_eq(pzw_ptr))])
        ; MaybeSTag = yes(_),
            util.exception.sorry($file, $pred, "Secondary tags")
        )
    ).

:- pred gen_deconstruction(code_gen_info::in, expr_pattern::in, type_::in,
    val_locn_map::in, val_locn_map::out, int::in, int::out,
    cord(pz_instr_obj)::out) is det.

gen_deconstruction(_, p_num(_), _, !LocnMap, !Depth, Instrs) :-
    % Drop the switched on variable when entering the branch.
    Instrs = singleton(pzio_instr(pzi_drop)),
    !:Depth = !.Depth - 1.
gen_deconstruction(_, p_wildcard, _, !LocnMap, !Depth, Instrs) :-
    % Drop the switched on variable when entering the branch.
    Instrs = singleton(pzio_instr(pzi_drop)),
    !:Depth = !.Depth - 1.
gen_deconstruction(CGInfo, p_variable(Var), _, !LocnMap, !Depth,
        Instrs) :-
    Varmap = CGInfo ^ cgi_varmap,
    % Leave the value on the stack and update the bind map so that the
    % expression can find it.
    % NOTE: This call expects the depth where the variable begins.
    vl_put_vars([Var], !.Depth - 1, Varmap, Instrs, !LocnMap).
gen_deconstruction(CGInfo, p_ctor(CtorIds, Args), VarType, !LocnMap, !Depth,
        Instrs) :-
    (
        VarType = type_ref(TypeId, _),
        CtorId = one_item_in_set(CtorIds),
        map.lookup(CGInfo ^ cgi_type_ctor_tags, {TypeId, CtorId}, CtorData),
        TagInfo = CtorData ^ cd_tag_info,
        (
            ( TagInfo = ti_constant(_, _)
            ; TagInfo = ti_constant_notag(_)
            ),
            % Discard the value, it doesn't bind any variables.
            Instrs = singleton(pzio_instr(pzi_drop)),
            !:Depth = !.Depth - 1
        ; TagInfo = ti_tagged_pointer(_, StructId, MaybeSTag),
            ( MaybeSTag = no,
                FirstField = field_num(1)
            ; MaybeSTag = yes(_),
                FirstField = field_num(2)
            ),

            % Untag the pointer, TODO: skip this if it's known that the tag
            % is zero.
            BreakTag = CGInfo ^ cgi_builtin_ids ^ pbi_break_tag,
            InstrsUntag = cord.from_list([
                pzio_comment("Untag pointer and deconstruct"),
                pzio_instr(pzi_call(pzc_import(BreakTag))),
                pzio_instr(pzi_drop)]),

            % TODO: Optimisation, only read the variables that are used in
            % the body.  Further optimisation could leave some on the heap,
            % avoiding stack usage.
            core_get_constructor_det(CGInfo ^ cgi_core, CtorId, Ctor),
            Varmap = CGInfo ^ cgi_varmap,
            gen_decon_fields(Varmap, StructId, Args, Ctor ^ c_fields,
                FirstField, InstrsDeconstruct, !LocnMap, !Depth),
            InstrDrop = pzio_instr(pzi_drop),
            Instrs = InstrsUntag ++ InstrsDeconstruct ++ singleton(InstrDrop),
            !:Depth = !.Depth - 1
        )
    ;
        ( VarType = builtin_type(_)
        ; VarType = type_variable(_)
        ; VarType = func_type(_, _, _, _)
        ),
        unexpected($file, $pred,
            "Deconstructions must be on user types")
    ).

:- pred gen_decon_fields(varmap::in, pzs_id::in,
    list(var)::in, list(type_field)::in, field_num::in, cord(pz_instr_obj)::out,
    val_locn_map::in, val_locn_map::out, int::in, int::out) is det.

gen_decon_fields(_,      _,        [],           [],               _,
        init, !LocnMap, !Depth).
gen_decon_fields(_,      _,        [],           [_ | _],          _,
        _,    !LocnMap, !Depth) :-
    unexpected($file, $pred, "Mismatched arg/field lists").
gen_decon_fields(_,      _,        [_ | _],      [],               _,
        _,    !LocnMap, !Depth) :-
    unexpected($file, $pred, "Mismatched arg/field lists").
gen_decon_fields(Varmap, StructId, [Arg | Args], [Field | Fields], FieldNo,
        InstrsField ++ InstrsFields, !LocnMap, !Depth) :-
    gen_decon_field(Varmap, StructId, Arg, Field, FieldNo,
        InstrsField,  !LocnMap, !Depth),
    gen_decon_fields(Varmap, StructId, Args, Fields, field_num_next(FieldNo),
        InstrsFields, !LocnMap, !Depth).

:- pred gen_decon_field(varmap::in, pzs_id::in, var::in, type_field::in,
    field_num::in, cord(pz_instr_obj)::out,
    val_locn_map::in, val_locn_map::out, int::in, int::out) is det.

gen_decon_field(Varmap, StructId, Var, _Field, FieldNo, Instrs, !LocnMap,
        !Depth) :-
    Instrs = cord.from_list([
        pzio_comment(format("reading field %d", [i(FieldNo ^ field_num_int)])),
        pzio_instr(pzi_load(StructId, FieldNo, pzw_ptr)),
        pzio_comment(format("%s is at depth %d",
            [s(get_var_name(Varmap, Var)), i(!.Depth)]))
        ]),

    % Update the LocnMap
    vl_put_var(Var, !.Depth, !LocnMap),

    % Load is (ptr - * ptr) so we increment the depth here.
    !:Depth = !.Depth + 1.

%-----------------------------------------------------------------------%

:- func gen_construction(code_gen_info, type_, ctor_id) =
    cord(pz_instr_obj).

gen_construction(CGInfo, Type, CtorId) = Instrs :-
    ( Type = builtin_type(_),
        unexpected($file, $pred, "No builtin types are constructed with
        e_construction")
    ; Type = type_variable(_),
        unexpected($file, $pred, "Polymorphic values are never constructed")
    ; Type = type_ref(TypeId, _),
        map.lookup(CGInfo ^ cgi_type_ctor_tags, {TypeId, CtorId}, CtorData),
        CtorProc = CtorData ^ cd_construct_proc,

        Instrs = from_list([
            pzio_comment("Call constructor"),
            pzio_instr(pzi_call(pzc_proc_opt(CtorProc)))])
    ; Type = func_type(_, _, _, _),
        util.exception.sorry($file, $pred, "Function type")
    ).

%-----------------------------------------------------------------------%

:- pred gen_closure(code_gen_info::in, func_id::in, list(var)::in,
    int::in, val_locn_map::in, cord(pz_instr_obj)::out) is det.

gen_closure(CGInfo, FuncId, Captured, !.Depth, LocnMap, Instrs) :-
    StructId = vl_lookup_closure(LocnMap, FuncId),
    AllocEnvInstrs = from_list([
            pzio_comment("Constructing closure"),
            pzio_instr(pzi_alloc(StructId))
        ]),
    !:Depth = !.Depth + 1,

    ModEnvLocn = vl_lookup_mod_env(LocnMap),
    SetModuleEnvFieldInstrs =
        gen_val_locn_access(CGInfo, !.Depth, LocnMap, ModEnvLocn) ++
        from_list([pzio_instr(pzi_swap),
                   pzio_instr(pzi_store(StructId, field_num_first, pzw_ptr))]),

    map_foldl(
        (pred(V::in, Is::out, FldN::in, field_num_next(FldN)::out) is det :-
            map.lookup(CGInfo ^ cgi_type_map, V, Type),
            Width = type_to_pz_width(Type),
            Is = gen_var_access(CGInfo, LocnMap, V, !.Depth) ++
                from_list([
                    pzio_instr(pzi_swap),
                    pzio_instr(pzi_store(StructId, FldN, Width))
                ])
        ), Captured, SetFieldsInstrs0, field_num_next(field_num_first), _),
    SetFieldsInstrs = cord_list_to_cord(SetFieldsInstrs0),

    ProcId = vl_lookup_proc_id(LocnMap, FuncId),
    MakeClosureInstrs = singleton(pzio_instr(pzi_make_closure(ProcId))),

    Instrs = AllocEnvInstrs ++ SetModuleEnvFieldInstrs ++ SetFieldsInstrs ++
        MakeClosureInstrs.

%-----------------------------------------------------------------------%

:- type continuation
    --->    cont_return
    ;       cont_jump(cj_depth :: int, cj_block :: pzb_id)
    ;       cont_instrs(int, cord(pz_instr_obj))
    ;       cont_comment(string, continuation)
    ;       cont_none(int).

    % gen_continuation(Continuation, Depth, NumItems, Why) = ContInstrs
    %
    % Generate the code for the continuation.  The continuation may need to
    % adjust the stack which is currently Depth + NumItems.  NumItems is the
    % number of items that the continuation will want to process.  Why is a
    % label to help debug code generation, it shows why we're making this
    % continuation (ie the caller).
    %
    % TODO: Why doesn't the continuation itself know about NumItems?
    %
:- func gen_continuation(continuation, int, int, string) = cord(pz_instr_obj).

gen_continuation(Cont, Depth, Items, Why) =
    cons(pzio_comment(format(
            "Continuation at depth %d with %d items from %s",
            [i(Depth), i(Items), s(Why)])),
        gen_continuation_2(Cont, Depth, Items)).

:- func gen_continuation_2(continuation, int, int) = cord(pz_instr_obj).

gen_continuation_2(cont_return, Depth, Items) =
    snoc(fixup_stack(Depth, Items), pzio_instr(pzi_ret)).
gen_continuation_2(cont_jump(WantDepth, Block), CurDepth, Items) =
        snoc(FixupStack, pzio_instr(pzi_jmp(Block))) :-
    % Fixup the stack to put it at Depth plus Items.
    % Wanted depth includes the items on the stack, so we add them here.
    BottomItems = CurDepth + Items - WantDepth,
    FixupStack = fixup_stack(BottomItems, Items).
gen_continuation_2(cont_instrs(WantDepth, Instrs), CurDepth, Items) =
        FixupStack ++ CommentInstrs ++ Instrs :-
    % Fixup the stack to put it at Depth plus Items.
    % Wanted depth includes the items on the stack, so we add them here.
    BottomItems = CurDepth + Items - WantDepth,
    FixupStack = fixup_stack(BottomItems, Items),
    CommentInstrs = singleton(pzio_comment(
        format("Continuation depth is %d", [i(WantDepth)]))).
gen_continuation_2(cont_comment(Comment, Continuation), CurDepth, Items) =
    cons(pzio_comment(Comment),
         gen_continuation_2(Continuation, CurDepth, Items)).
gen_continuation_2(cont_none(WantDepth), CurDepth, Items) =
    singleton(pzio_comment("No continuation")) ++
    fixup_stack(CurDepth - WantDepth, Items).

:- pred continuation_make_block(continuation::in, continuation::out,
    pz_blocks::in, pz_blocks::out) is det.

continuation_make_block(cont_return, cont_return, !Blocks).
continuation_make_block(cont_jump(Depth, Block), cont_jump(Depth, Block),
    !Blocks).
continuation_make_block(cont_instrs(Depth, Instrs), cont_jump(Depth, BlockId),
        !Blocks) :-
    alloc_block(BlockId, !Blocks),
    create_block(BlockId, Instrs, !Blocks).
continuation_make_block(cont_comment(Comment, Cont0),
        cont_comment(Comment, Cont), !Blocks) :-
    continuation_make_block(Cont0, Cont, !Blocks).
continuation_make_block(cont_none(Depth), cont_none(Depth), !Blocks).

%-----------------------------------------------------------------------%

:- func depth_comment_instr(int) = pz_instr_obj.

depth_comment_instr(Depth) = pzio_comment(format("Depth: %d", [i(Depth)])).

:- func gen_var_access(code_gen_info, val_locn_map, var, int) =
    cord(pz_instr_obj).

gen_var_access(CGInfo, LocnMap, Var, Depth) = Instrs :-
    VarName = get_var_name(CGInfo ^ cgi_varmap, Var),
    CommentInstr = pzio_comment(format("get var %s", [s(VarName)])),
    ( if vl_search_var(LocnMap, Var, VarLocn) then
        Instrs = singleton(CommentInstr) ++
            gen_val_locn_access(CGInfo, Depth, LocnMap, VarLocn)
    else
        core_get_function_det(CGInfo ^ cgi_core, CGInfo ^ cgi_this_func,
            Func),
        FuncName = func_get_name(Func),
        unexpected($file, $pred,
            format("The code generator could not find the location of " ++
                "a variable '%s' when compiling '%s'. " ++
                "This is most-likely a bug in an earlier pass",
                [s(VarName), s(q_name_to_string(FuncName))]))
    ).

:- pred gen_instrs_args(code_gen_info::in, val_locn_map::in,
    list(var)::in, cord(pz_instr_obj)::out, int::in, int::out) is det.

gen_instrs_args(CGInfo, LocnMap, Args, InstrsArgs, !Depth) :-
    map_foldl((pred(V::in, I::out, D0::in, D::out) is det :-
            I = gen_var_access(CGInfo, LocnMap, V, D0),
            D = D0 + 1
        ), Args, InstrsArgs0, !Depth),
    InstrsArgs = cord_list_to_cord(InstrsArgs0).

%-----------------------------------------------------------------------%

:- func gen_val_locn_access(code_gen_info, int, val_locn_map, val_locn) =
    cord(pz_instr_obj).

gen_val_locn_access(CGInfo, Depth, _, vl_stack(VarDepth, Next)) =
        Instrs ++ gen_val_locn_access_next(CGInfo, Next) :-
    RelDepth = Depth - VarDepth + 1,
    Instrs = from_list([
        pzio_comment("value is on the stack"),
        pzio_instr(pzi_pick(RelDepth))]).
gen_val_locn_access(CGInfo, _, _, vl_env(Next)) =
    from_list([
            pzio_comment("value is available from the environment"),
            pzio_instr(pzi_get_env)]) ++
        gen_val_locn_access_next(CGInfo, Next).
gen_val_locn_access(CGInfo, Depth, LocnMap, vl_compute(Expr)) = Instrs :-
    % + Don't generate blocks (test that Expr has no case)
    % + Don't require continuation.
    gen_instrs(CGInfo, Expr, Depth, LocnMap, cont_none(Depth), Instrs,
        pz_blocks(0u32, map.init), pz_blocks(LastBlockNo, _)),
    ( if LastBlockNo \= 0u32 then
        unexpected($file, $pred, "Cannot create blocks here")
    else
        true
    ).

:- func gen_val_locn_access_next(code_gen_info, val_locn_next) =
    cord(pz_instr_obj).

gen_val_locn_access_next(_, vln_done) = init.
gen_val_locn_access_next(CGInfo, vln_struct(StructId, Field, Width, Next)) =
        Instrs ++ gen_val_locn_access_next(CGInfo, Next) :-
    StructName = lookup(CGInfo ^ cgi_struct_names, StructId),
    Instrs = from_list([
        pzio_comment(format("Lookup in %s", [s(StructName)])),
        pzio_instr(pzi_load(StructId, Field, Width)),
        pzio_instr(pzi_drop)]).

%-----------------------------------------------------------------------%

:- type pz_blocks
    --->    pz_blocks(
                pzb_next_block  :: pzb_id,
                pzb_blocks      :: map(pzb_id, pz_block)
            ).

:- pred alloc_block(pzb_id::out, pz_blocks::in, pz_blocks::out) is det.

alloc_block(BlockId, !Blocks) :-
    BlockId = !.Blocks ^ pzb_next_block,
    !Blocks ^ pzb_next_block := BlockId + 1u32.

:- pred create_block(pzb_id::in, cord(pz_instr_obj)::in,
    pz_blocks::in, pz_blocks::out) is det.

create_block(BlockId, Instrs, !Blocks) :-
    Block = pz_block(cord.list(Instrs)),
    BlockMap0 = !.Blocks ^ pzb_blocks,
    det_insert(BlockId, Block, BlockMap0, BlockMap),
    !Blocks ^ pzb_blocks := BlockMap.

%-----------------------------------------------------------------------%

:- pred initial_bind_map(list(var)::in, int::in, varmap::in,
    cord(pz_instr_obj)::out, val_locn_map::in, val_locn_map::out)
    is det.

initial_bind_map(Vars, Depth, Varmap, Comments, !Map) :-
    vl_put_vars(Vars, Depth, Varmap, Comments, !Map).

%-----------------------------------------------------------------------%

    % This algorithm walks the expression tree.
    %
    % When it encouters the introduction of a new variable via a let
    % expression (but not pattern matches) and the expression does not use
    % or observe a resource, it ads it to the !ZeroUses set.
    %
    % When it sees the use of a it:
    %  + If the variable is in !SeenZero it moves it to !SeenOne.
    %  + IF the variable is in !SeenOne it removes it.
    %
    % When it terminates the bindings in !SeenZero can be optimised away
    % completely, and those in !SeenOne can be moved into their only use
    % site.
    %
:- pred find_oneuse_vars(expr::in, set(var)::in, set(var)::out,
    set(var)::in, set(var)::out) is det.

find_oneuse_vars(expr(Type, _), !ZeroUses, !OneUse) :-
    ( Type = e_tuple(Exprs),
        foldl2(find_oneuse_vars, Exprs, !ZeroUses, !OneUse)
    ; Type = e_lets(Lets, Expr),
        foldl2(find_oneuse_vars_let, Lets, !ZeroUses, !OneUse),
        find_oneuse_vars(Expr, !ZeroUses, !OneUse)
    ; Type = e_call(Callee, Args, _),
        ( Callee = c_plain(_)
        ; Callee = c_ho(Var),
            find_oneuse_vars_var(Var, !ZeroUses, !OneUse)
        ),
        foldl2(find_oneuse_vars_var, Args, !ZeroUses, !OneUse)
    ; Type = e_var(Var),
        find_oneuse_vars_var(Var, !ZeroUses, !OneUse)
    ; Type = e_constant(_)
    ; Type = e_construction(_, Args),
        foldl2(find_oneuse_vars_var, Args, !ZeroUses, !OneUse)
    ; Type = e_closure(_, Args),
        foldl2(find_oneuse_vars_var, Args, !ZeroUses, !OneUse)
    ; Type = e_match(Var, Cases),
        find_oneuse_vars_var(Var, !ZeroUses, !OneUse),
        foldl2(find_oneuse_vars_case, Cases, !ZeroUses, !OneUse)
    ).

:- pred find_oneuse_vars_let(expr_let::in, set(var)::in, set(var)::out,
    set(var)::in, set(var)::out) is det.

find_oneuse_vars_let(e_let(Vars, Expr), !ZeroUses, !OneUse) :-
    find_oneuse_vars(Expr, !ZeroUses, !OneUse),
    union(list_to_set(Vars), !ZeroUses).

:- pred find_oneuse_vars_case(expr_case::in, set(var)::in, set(var)::out,
    set(var)::in, set(var)::out) is det.

find_oneuse_vars_case(e_case(Pat, Expr), !ZeroUses, !OneUse) :-
    ( Pat = p_num(_)
    ; Pat = p_variable(Var),
        insert(Var, !ZeroUses)
    ; Pat = p_wildcard
    ; Pat = p_ctor(_, Vars),
        union(list_to_set(Vars), !ZeroUses)
    ),
    find_oneuse_vars(Expr, !ZeroUses, !OneUse).

:- pred find_oneuse_vars_var(var::in, set(var)::in, set(var)::out,
    set(var)::in, set(var)::out) is det.

find_oneuse_vars_var(Var, !ZeroUse, !OneUse) :-
    ( if remove(Var, !OneUse) then
        true
    else if remove(Var, !ZeroUse) then
        insert(Var, !OneUse)
    else
        true
    ).

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
