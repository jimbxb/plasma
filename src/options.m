%-----------------------------------------------------------------------%
% Plasma compiler options
% vim: ts=4 sw=4 et
%
% Copyright (C) 2015-2016, 2018, 2020 Plasma Team
% Distributed under the terms of the MIT License see ../LICENSE.code
%
% The options structure for the Plasma compiler.
%
%-----------------------------------------------------------------------%
:- module options.
%-----------------------------------------------------------------------%

:- interface.

:- import_module bool.

%-----------------------------------------------------------------------%

:- type general_options
    --->    general_options(
                % High-level options
                go_dir              :: string, % The directory of the input
                                               % file.
                go_input_file       :: string,
                go_output_file      :: string,

                % Diagnostic options.
                go_verbose          :: bool,
                go_dump_stages      :: dump_stages,
                go_write_output     :: write_output
    ).

:- type compile_options
    --->    compile_options(
                % Feature/optimisation options
                % Although we're not generally implementing optimisations or
                % these options control some optional transformations during
                % compilation, by making them options they're easier toe
                % test.
                co_do_simplify      :: do_simplify,
                co_enable_tailcalls :: enable_tailcalls
            ).

:- type dump_stages
    --->    dump_stages
    ;       dont_dump_stages.

:- type write_output
    --->    write_output
    ;       dont_write_output.

:- type do_simplify
    --->    do_simplify_pass
    ;       skip_simplify_pass.

:- type enable_tailcalls
    --->    enable_tailcalls
    ;       dont_enable_tailcalls.

%-----------------------------------------------------------------------%
%-----------------------------------------------------------------------%
