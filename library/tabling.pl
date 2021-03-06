/*  Part of SWI-Prolog

    Author:        Benoit Desouter <Benoit.Desouter@UGent.be>
                   Jan Wielemaker (SWI-Prolog port)
    Copyright (c)  2016, Benoit Desouter
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(tabling,
          [ (table)/1,                  % +PI ...

            current_table/2,            % :Variant, ?Table
            abolish_all_tables/0,
            abolish_table_subgoals/1,   % :Subgoal

            start_tabling/2,            % +Wrapper, :Worker.

            op(1150, fx, table)
          ]).
:- use_module(library(error)).
:- set_prolog_flag(generate_debug_info, false).

:- meta_predicate
    start_tabling(+, 0),
    current_table(:, -),
    abolish_table_subgoals(:).
%    get_wrapper_no_mode_args(:,:).
%    add_answer(+,0,0).
  %  extract_mode_args(+,:,-),
  %  get_modes(:,-).

/** <module> Tabled execution (SLG WAM)

This  library  handled  _tabled_  execution   of  predicates  using  the
characteristics if the _SLG WAM_. The   required  suspension is realised
using _delimited continuations_ implemented by  reset/3 and shift/1. The
table space and work lists are part of the SWI-Prolog core.

@author Benoit Desouter
*/

%!  table(+PredicateIndicators)
%
%   Prepare the given PredicateIndicators for   tabling. Can only be
%   used as a directive. The example   below  prepares the predicate
%   edge/2 and the non-terminal statement//1 for tabled execution.
%
%     ==
%     :- table edge/2, statement//1.
%     ==

table(PIList) :-
    throw(error(context_error(nodirective, table(PIList)), _)).

%!  start_tabling(+Variant, +Implementation)
%
%   Execute Implementation using tabling. This  predicate should not
%   be called directly. The table/1 directive  causes a predicate to
%   be translated into a renamed implementation   and a wrapper that
%   involves this predicate.
%
%   @compat This interface may change or disappear without notice
%           from future versions.

start_tabling(Wrapper,Worker) :-
    get_wrapper_no_mode_args(Wrapper,WrapperNoModes,ModeArgs),
    '$tbl_variant_table'(WrapperNoModes, Trie, Status),
    (   Status == complete
    ->  trie_gen(Trie, WrapperNoModes, ModeArgs)
    ;   (   '$tbl_scheduling_component'(false, true)
        ->  catch(run_leader(Wrapper, WrapperNoModes, Worker, Trie), E, true),
            (   var(E)
            ->   trie_gen(Trie, WrapperNoModes, ModeArgs)
            ;   '$tbl_table_discard_all',
                throw(E)
            )
        ;   run_follower(Status, Wrapper, WrapperNoModes, Worker, Trie)
        )
    ).

get_wrapper_no_mode_args(M:Wrapper,M:WrapperNoModes,ModeArgs):-
    M:'$table_modes'(Wrapper,_),!,
    extract_mode_args(M:Wrapper, ModeArgs, WrapperNoModes).

get_wrapper_no_mode_args(Wrapper,Wrapper,[]).

run_follower(fresh, Wrapper, WrapperNoModes, Worker, Trie) :-
    !,
    activate(Wrapper, WrapperNoModes, Worker, Trie, Worklist),
    shift(call_info(Wrapper, Worklist)).
run_follower(Worklist, Wrapper, _WrapperNoModes, _Worker, _Trie) :-
    shift(call_info(Wrapper, Worklist)).

run_leader(Wrapper, WrapperNoModes, Worker, Trie) :-
    activate(Wrapper, WrapperNoModes, Worker, Trie, _Worklist),
    completion,
    '$tbl_scheduling_component'(_, false).

activate(Wrapper, WrapperNoModes, Worker, Trie, WorkList) :-
    '$tbl_new_worklist'(WorkList, Trie),
    (   delim(Wrapper, WrapperNoModes, Worker, WorkList),
        fail
    ;   true
    ).

delim(Wrapper, WrapperNoModes, Worker, WorkList) :-
    reset(Worker,SourceCall,Continuation),
    (   Continuation == 0
    ->  add_answer(WorkList,Wrapper,WrapperNoModes)

    ;   SourceCall = call_info(SrcWrapper, SourceWL),
        TargetCall = call_info(Wrapper,    WorkList),
        Dependency = dependency(SrcWrapper,Continuation,TargetCall),
        '$tbl_wkl_add_suspension'(SourceWL, Dependency)
    ).

add_answer(WorkList, M:Wrapper,M:Wrapper):-
     !,
%    no mode directed tabling
    '$tbl_wkl_add_answer'(WorkList, M:Wrapper).

add_answer(WorkList, M:Wrapper, M:WrapperNoModes):-
% mode directed tabling
    extract_mode_args(M:Wrapper, ModeArgs, _WrapperNoModes),
    '$tbl_wkl_mode_add_answer'(WorkList, M:WrapperNoModes,ModeArgs,M:Wrapper).

extract_mode_args(M:Wrapper, ModeArgs, WrapperNoModes):-
  get_modes(M:Wrapper, Modes),
  Wrapper =.. [P|Args],
  separate_args(Modes,Args,NoModesArgs,ModeArgs),
  WrapperNoModes =.. [P|NoModesArgs].

update(M:Wrapper,A1,A2,A3):-
  get_modes(M:Wrapper, Modes),
  get_mode_list(Modes,Preds),
  maplist(join(M),Preds,A1,A2,A3).

get_modes(M:Wrapper,Modes):-
  functor(Wrapper,Name,Args),
  functor(Head,Name,Args),
  M:'$table_modes'(Head, Modes).

get_mode_list([],[]).

get_mode_list([H|TM],TP):-
  var(H),!,
  get_mode_list(TM,TP).

get_mode_list([H|TM],[H|TP]):-
  get_mode_list(TM,TP).


join(M,Pred,E1,E2,E3):-
  M:call(Pred,E1,E2,E3).

completion :-
    '$tbl_pop_worklist'(WorkList),
    !,
    completion_step(WorkList),
    completion.
completion :-
    '$tbl_table_complete_all'.

completion_step(SourceTable) :-
    (   '$tbl_wkl_work'(SourceTable, Answer, ModeArgs, Dependency),
        dep(Answer, ModeArgs,Dependency, Wrapper,Continuation,TargetTable),
        get_wrapper_no_mode_args(Wrapper,WrapperNoModes,_ModeArgs),
        delim(Wrapper,WrapperNoModes,Continuation,TargetTable),
        fail
    ;   true
    ).

dep(Answer,ModeArgs, dependency(Goal, Continuation, call_info(Wrapper, TargetTable)),
    Wrapper, Continuation,TargetTable):-
            get_wrapper_no_mode_args(Goal,Answer,ModeArgs).


                 /*******************************
                 *            CLEANUP           *
                 *******************************/

%!  abolish_all_tables
%
%   Remove all tables. This is normally used to free up the space or
%   recompute the result after predicates on   which  the result for
%   some tabled predicates depend.
%
%   @error  permission_error(abolish, table, all) if tabling is
%           in progress.

abolish_all_tables :-
    '$tbl_abolish_all_tables'.

%!  abolish_table_subgoals(:Subgoal) is det.
%
%   Abolish all tables that unify with SubGoal.

abolish_table_subgoals(M:SubGoal) :-
    '$tbl_variant_table'(VariantTrie),
    current_module(M),
    forall(trie_gen(VariantTrie, M:SubGoal, Trie),
           '$tbl_destroy_table'(Trie)).


                 /*******************************
                 *        EXAMINE TABLES        *
                 *******************************/

%!  current_table(:Variant, -Trie) is nondet.
%
%   True when Trie is the answer table for Variant.

current_table(M:Variant, Trie) :-
    '$tbl_variant_table'(VariantTrie),
    (   (var(Variant) ; var(M))
    ->  trie_gen(VariantTrie, M:Variant, Trie)
    ;   trie_lookup(VariantTrie, M:Variant, Trie)
    ).


                 /*******************************
                 *      WRAPPER GENERATION      *
                 *******************************/

:- multifile
    system:term_expansion/2,
    prolog:rename_predicate/2,
    tabled/2.
:- dynamic
    system:term_expansion/2.

wrappers(Var) -->
    { var(Var),
      !,
      instantiation_error(Var)
    }.
wrappers((A,B)) -->
    !,
    wrappers(A),
    wrappers(B).
wrappers(Name//Arity) -->
    { atom(Name), integer(Arity), Arity >= 0,
      !,
      Arity1 is Arity+2
    },
    wrappers(Name/Arity1).
wrappers(Name/Arity) -->
    { atom(Name), integer(Arity), Arity >= 0,
      !,
      functor(Head, Name, Arity),
      atom_concat(Name, ' tabled', WrapName),
      Head =.. [Name|Args],
      WrappedHead =.. [WrapName|Args],
      prolog_load_context(module, Module)
    },
    [ '$tabled'(Head),
      (   Head :-
             start_tabling(Module:Head, WrappedHead)
      )
    ].
wrappers(ModeDirectedSpec) -->
    {
      functor(ModeDirectedSpec, Name, Arity),
      ModeDirectedSpec=..[Name|Modes],
      functor(Head, Name, Arity),
      atom_concat(Name, ' tabled', WrapName),
      Head =.. [Name|Args],
      WrappedHead =.. [WrapName|Args],
%      separate_args(Modes,Args,NoModesArg,_ModeArgs),
%      HeadNoModeArgs =..[Name|NoModesArg],
      prolog_load_context(module, Module)
    },
    [ '$tabled'(Head),
      '$table_modes'(Head,Modes),
      (   Head :-
             start_tabling(Module:Head, WrappedHead)
      )
    ].

separate_args([],[],[],[]).

separate_args([HM|TM],[H|TA],[H|TNA],TMA):-
  var(HM),!,
  separate_args(TM,TA,TNA,TMA).

separate_args([_H|TM],[H|TA],TNA,[H|TMA]):-
  separate_args(TM,TA,TNA,TMA).

%!  prolog:rename_predicate(:Head0, :Head) is semidet.
%
%   Hook into term_expansion for  post   processing  renaming of the
%   generated predicate.

prolog:rename_predicate(M:Head0, M:Head) :-
    '$flushed_predicate'(M:'$tabled'(_)),
    call(M:'$tabled'(Head0)),
    !,
    rename_term(Head0, Head).

rename_term(Compound0, Compound) :-
    compound(Compound0),
    !,
    compound_name_arguments(Compound0, Name, Args),
    atom_concat(Name, ' tabled', WrapName),
    compound_name_arguments(Compound, WrapName, Args).
rename_term(Name, WrapName) :-
    atom_concat(Name, ' tabled', WrapName).


system:term_expansion((:- table(Preds)),
                      [ (:- discontiguous('$tabled'/1)),
                        (:- dynamic('$table_modes'/2)),
                        (:- discontiguous('$table_modes'/2))
                      | Clauses
                      ]) :-
    phrase(wrappers(Preds), Clauses).


                 /*******************************
                 *           SANDBOX            *
                 *******************************/

:- multifile
    sandbox:safe_directive/1,
    sandbox:safe_primitive/1,
    sandbox:safe_meta/2.

%!  sandbox:safe_directive(+Directive) is semidet.
%
%   Allow tabling directives that affect locally defined predicates.

sandbox:safe_directive(Dir) :-
    ground(Dir),
    local_tabling_dir(Dir).

local_tabling_dir(table(Preds)) :-
    local_preds(Preds).

local_preds((A,B)) :-
    !,
    local_preds(A),
    local_preds(B).

local_preds(Name/Arity) :-
    atom(Name), integer(Arity).
local_preds(Name//Arity) :-
    atom(Name), integer(Arity).

sandbox:safe_meta_predicate(tabling:start_tabling/2).

sandbox:safe_primitive(tabling:abolish_all_tables).
sandbox:safe_meta(tabling:abolish_table_subgoals(V), []) :-
    \+ qualified(V).
sandbox:safe_meta(tabling:current_table(V, _), []) :-
    \+ qualified(V).

qualified(V) :-
    nonvar(V),
    V = _:_.
