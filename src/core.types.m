%-----------------------------------------------------------------------%
% Plasma types representation
% vim: ts=4 sw=4 et
%
% Copyright (C) 2015-2016 Plasma Team
% Distributed under the terms of the MIT License see ../LICENSE.code
%
%-----------------------------------------------------------------------%
:- module core.types.
%-----------------------------------------------------------------------%

:- interface.

:- import_module string.

%-----------------------------------------------------------------------%

:- type type_
    --->    builtin_type(builtin_type)
    ;       type_variable(type_var)
    ;       type_ref(type_id).

:- type type_var == string.

:- type builtin_type
    --->    int
            % string may not always be builtin.
    ;       string.

:- pred builtin_type_name(builtin_type, string).
:- mode builtin_type_name(in, out) is det.
:- mode builtin_type_name(out, in) is semidet.

%-----------------------------------------------------------------------%

:- type user_type.

:- func init(q_name, list(ctor_id)) = user_type.

:- func type_get_name(user_type) = q_name.

%-----------------------------------------------------------------------%

:- type constructor
    --->    constructor(
                c_name          :: q_name,
                c_fields        :: list(type_field)
            ).

:- type type_field
    --->    type_field(
                tf_name         :: q_name,
                tf_type         :: type_
            ).

%-----------------------------------------------------------------------%

:- type ctor_tag_info
    --->    ti_constant(
                tic_ptag            :: int,
                tic_word_bits       :: int
            )
    ;       ti_constant_notag(
                ticnw_bits          :: int
            )
    ;       ti_tagged_pointer(
                titp_ptag           :: int
            ).

:- pred type_setup_ctor_tags(core::in, type_id::in,
    user_type::in, user_type::out) is det.

:- func type_get_ctor_tag(user_type, ctor_id) = ctor_tag_info.

:- func num_ptag_bits = int.

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
:- implementation.

%-----------------------------------------------------------------------%

builtin_type_name(int,      "Int").
builtin_type_name(string,   "String").

%-----------------------------------------------------------------------%

:- type user_type
    --->    user_type(
                t_symbol        :: q_name,
                t_ctors         :: list(ctor_id),
                t_tag_infos     :: map(ctor_id, ctor_tag_info)
            ).

init(Name, Ctors) = user_type(Name, Ctors, init).

type_get_name(Type) = Type ^ t_symbol.

%-----------------------------------------------------------------------%
%
% Pointer tagging
% ===============
%
% All memory allocations are machine-word aligned, this means that there are
% two or three low-bits available for pointer tags (32bit or 64bit systems).
% There may be high bits available also, especially on 64bit systems.  For
% now we assume that there are always two low bits available.
%
% TODO: Optimization
% Using the third bit on a 64 bit system would be good.  This can be handled
% by compiling two versions of the program and storing them both in the .pz
% file.  One for 32-bit and one for 64-bit.  This would happen at a late
% stage of compilation and won't duplicate much work.  It could be skipped
% or stripped from the file to reduce file size if required.
%
% We use tagged pointers to implement discriminated unions.  Most of what we
% do here is based upon the Mercury project.  Each pointer's 2 lowest bits
% are the _primary tag_, a _secondary tag_ can be stored in the pointed-to
% object when required.
%
% Each type's constructors are grouped into those that have arguments, and
% those that do not.  The first primary tag "00" is used for the group of
% constants with the higher bits used to encode each constant.  The
% next remaining primary tags "01" "10" (and "00" if it was not used in the
% first step") are given to the first two-three constructors with arguments
% and the final tag "11" is used for all the remaining constructors,
% utilizing a second tag as the first field in the pointed-to structure to
% distinguish between them.
%
% This scheme has a specific benefit that is if there is only a single
% no-argument constructor then it has the same value as the null pointer.
% Therefore the cons cell has the same encoding as either a normal pointer
% or the null pointer.  Likewise a maybe value can be unboxed in some cases.
% (Not implemented yet).
%
% Exception: strict enums
% If a type is an enum _only_ then it doesn't require any tag bits and is
% encoded simply as a raw value.  This exception enables the bool type to
% use 0 and 1 conveniently.
%
% TODO: Optimisation:
% Special casing certain types, such as unboxing maybes, handling "no tag"
% types, etc.
%
%-----------------------------------------------------------------------%

type_setup_ctor_tags(Core, TypeId, !Type) :-
    CtorIds = !.Type ^ t_ctors,
    map((pred(CId::in, {CId, C}::out) is det :-
            core_get_constructor_det(Core, TypeId, CId, C)
        ), CtorIds, Ctors),
    count_constructor_types(Ctors, NumNoArgs, NumWithArgs),
    ( if NumWithArgs = 0 then
        % This is a simple enum and therefore we can use strict enum
        % tagging.
        foldl2(make_strict_enum_tag_info, CtorIds, 0, _, init, TagInfos)
    else
        ( if NumNoArgs \= 0 then
            foldl2(make_enum_tag_info(0), Ctors, 0, _, init, TagInfos0),
            NextPTag = 1
        else
            TagInfos0 = init,
            NextPTag = 0
        ),
        foldl3(make_ctor_tag_info, Ctors, NextPTag, _, 0, _, TagInfos0,
            TagInfos)
    ),

    !Type ^ t_tag_infos := TagInfos.

:- pred count_constructor_types(list({ctor_id, constructor})::in,
    int::out, int::out) is det.

count_constructor_types([], 0, 0).
count_constructor_types([{_, Ctor} | Ctors], NumNoArgs,
        NumWithArgs) :-
    count_constructor_types(Ctors, NumNoArgs0, NumWithArgs0),
    Args = Ctor ^ c_fields,
    ( Args = [],
        NumNoArgs = NumNoArgs0 + 1,
        NumWithArgs = NumWithArgs0
    ; Args = [_ | _],
        NumNoArgs = NumNoArgs0,
        NumWithArgs = NumWithArgs0 + 1
    ).

    % make_enum_tag_info(PTag, Ctor, ThisWordBits, NextWordBits,
    %   !TagInfoMap).
    %
:- pred make_enum_tag_info(int::in, {ctor_id, constructor}::in,
    int::in, int::out,
    map(ctor_id, ctor_tag_info)::in, map(ctor_id, ctor_tag_info)::out) is det.

make_enum_tag_info(PTag, {CtorId, Ctor}, !WordBits, !Map) :-
    Fields = Ctor ^ c_fields,
    ( Fields = [],
        det_insert(CtorId, ti_constant(PTag, !.WordBits), !Map),
        !:WordBits = !.WordBits + 1
    ; Fields = [_ | _]
    ).

    % make_strict_enum_tag_info(Ctor, ThisWordBits, NextWordBits,
    %   !TagInfoMap).
    %
:- pred make_strict_enum_tag_info(ctor_id::in, int::in, int::out,
    map(ctor_id, ctor_tag_info)::in, map(ctor_id, ctor_tag_info)::out) is det.

make_strict_enum_tag_info(Ctor, !WordBits, !Map) :-
    det_insert(Ctor, ti_constant_notag(!.WordBits), !Map),
    !:WordBits = !.WordBits + 1.

:- pred make_ctor_tag_info({ctor_id, constructor}::in, int::in, int::out,
    int::in, int::out,
    map(ctor_id, ctor_tag_info)::in, map(ctor_id, ctor_tag_info)::out) is det.

make_ctor_tag_info({CtorId, Ctor}, !PTag, !STag, !Map) :-
    Fields = Ctor ^ c_fields,
    ( Fields = []
    ; Fields = [_ | _],
        ( if !.PTag < pow(2, num_ptag_bits) then
            det_insert(CtorId, ti_tagged_pointer(!.PTag), !Map),
            !:PTag = !.PTag + 1
        else
            util.sorry($file, $pred, "Secondary tags not supported")
        )
    ).

%-----------------------------------------------------------------------%

type_get_ctor_tag(Type, CtorId) = TagInfo :-
    lookup(Type ^ t_tag_infos, CtorId, TagInfo).

%-----------------------------------------------------------------------%

num_ptag_bits = 2.

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
