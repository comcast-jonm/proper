%%% Copyright 2010 Manolis Papadakis (manopapad@gmail.com)
%%%            and Kostis Sagonas (kostis@cs.ntua.gr)
%%%
%%% This file is part of PropEr.
%%%
%%% PropEr is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% PropEr is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with PropEr.  If not, see <http://www.gnu.org/licenses/>.

%%% @author Manolis Papadakis <manopapad@gmail.com>
%%% @copyright 2010 Manolis Papadakis and Kostis Sagonas
%%% @version {@version}
%%% @doc The shrinking subsystem and all predefined shrinkers are contained in
%%%	 this module.

-module(proper_shrink).

-export([shrink/5]).
-export([number_shrinker/4, union_first_choice_shrinker/3,
	 union_recursive_shrinker/3]).

-export_type([shrinker/0]).

-include("proper_internal.hrl").


%%------------------------------------------------------------------------------
%% Types
%%------------------------------------------------------------------------------

-type forall2_clause() :: {'$forall2', proper_types:type(),
			   proper:dependent_test()}.
%% TODO: rename to 'shrinker_state()'?
-type state() :: 'init' | 'done' | {'shrunk',position(),state()} | term().
-type shrinker() :: fun((proper_gen:imm_instance(), proper_types:type(),
			state()) -> {[proper_gen:imm_instance()],state()}).


%%------------------------------------------------------------------------------
%% Main shrinking functions
%%------------------------------------------------------------------------------


-spec shrink(proper:imm_testcase(), proper:test(), proper:fail_reason(),
	     non_neg_integer(), proper:output_fun()) ->
    {non_neg_integer(),proper:imm_testcase()}.
shrink(ImmTestCase, Test, Reason, Shrinks, Print) ->
    shrink_to_fixpoint(ImmTestCase, Test, Reason, 0, Shrinks, Print).

-spec shrink_to_fixpoint(proper:imm_testcase(), proper:test(),
			 proper:fail_reason(), non_neg_integer(),
			 non_neg_integer(), proper:output_fun()) ->
	  {non_neg_integer(),proper:imm_testcase()}.
%% TODO: is it too much if we try to reach an equilibrium by repeaing all the
%%	 shrinkers?
%% TODO: is it possible to get stuck in an infinite loop (unions are the most
%%	 dangerous)? should we check if the returned values have been
%%	 encountered before?
shrink_to_fixpoint(ImmFailedTestCase, _Test, _Reason,
		   TotalShrinks, 0, _Print) ->
    {TotalShrinks, ImmFailedTestCase};
shrink_to_fixpoint(ImmFailedTestCase, Test, Reason,
		   TotalShrinks, ShrinksLeft, Print) ->
    {Shrinks, ImmMinTestCase} =
	shrink_tr([], ImmFailedTestCase, proper:skip_to_next(Test), Reason,
		  0, ShrinksLeft, init, Print),
    case Shrinks of
	0 -> {TotalShrinks, ImmMinTestCase};
	N -> shrink_to_fixpoint(ImmMinTestCase, Test, Reason,
				TotalShrinks + N, ShrinksLeft - N, Print)
    end.

-spec shrink_tr(proper:imm_testcase(), proper:imm_testcase(),
		proper:forall_clause() | forall2_clause(), proper:fail_reason(),
		non_neg_integer(), non_neg_integer(), state(),
		proper:output_fun()) ->
	  {non_neg_integer(),proper:imm_testcase()}.
%% TODO: 'tries_left' instead of 'shrinks_left'?
shrink_tr(Shrunk, TestTail, error, _Reason,
	  Shrinks, _ShrinksLeft, _State, _Print) ->
    io:format("~nInternal Error: skip_to_next returned error~n", []),
    {Shrinks, lists:reverse(Shrunk) ++ TestTail};
shrink_tr(Shrunk, TestTail, _Test, _Reason, Shrinks, 0, _State, _Print) ->
    {Shrinks, lists:reverse(Shrunk) ++ TestTail};
shrink_tr(Shrunk, [], false, _Reason, Shrinks, _ShrinksLeft, init, _Print) ->
    {Shrinks, lists:reverse(Shrunk)};
shrink_tr(Shrunk, TestTail, {'$forall',RawType,Prop}, Reason,
	  Shrinks, ShrinksLeft, init, Print) ->
    Type = proper_types:cook_outer(RawType),
    shrink_tr(Shrunk, TestTail, {'$forall2',Type,Prop}, Reason,
	      Shrinks, ShrinksLeft, init, Print);
shrink_tr(Shrunk, [ImmInstance | Rest], {'$forall2',_Type,Prop}, Reason,
	  Shrinks, ShrinksLeft, done, Print) ->
    Instance = proper_gen:clean_instance(ImmInstance),
    NewTest = proper:skip_to_next({'$apply',[Instance],Prop}),
    shrink_tr([ImmInstance | Shrunk], Rest, NewTest, Reason,
	      Shrinks, ShrinksLeft, init, Print);
shrink_tr(Shrunk, TestTail = [ImmInstance | Rest],
	  Test = {'$forall2',Type,Prop}, Reason,
	  Shrinks, ShrinksLeft, State, Print) ->
    {NewImmInstances,NewState} = shrink_one(ImmInstance, Type, State),
    %% we also test if the recently returned instance is a valid instance
    %% for its type, since we don't check constraints while shrinking
    %% TODO: perhaps accept an 'unknown'?
    %% TODO: maybe this covers the LET parts-type test too?
    %% TODO: should we try producing new test tails while shrinking?
    IsValid =
	fun(I) ->
	    I =/= ImmInstance andalso
	    proper:still_fails([I | Rest], {'$forall',Type,Prop}, Reason)
	end,
    case find_first(IsValid, NewImmInstances) of
	none ->
	    shrink_tr(Shrunk, TestTail, Test, Reason,
		      Shrinks, ShrinksLeft, NewState, Print);
	{Pos, ShrunkImmInstance} ->
	    Print(".", []),
	    shrink_tr(Shrunk, [ShrunkImmInstance | Rest], Test, Reason,
		      Shrinks+1, ShrinksLeft-1, {shrunk,Pos,NewState}, Print)
    end.

-spec find_first(fun((T) -> boolean()), [T]) -> {position(),T} | 'none'.
find_first(Pred, List) ->
    find_first_tr(Pred, List, 1).

-spec find_first_tr(fun((T) -> boolean()), [T], position()) ->
	  {position(),T} | 'none'.
find_first_tr(_Pred, [], _Pos) ->
    none;
find_first_tr(Pred, [X | Rest], Pos) ->
    case Pred(X) of
	true  -> {Pos, X};
	false -> find_first_tr(Pred, Rest, Pos + 1)
    end.

-spec shrink_one(proper_gen:imm_instance(), proper_types:type(), state()) ->
	  {[proper_gen:imm_instance()],state()}.
shrink_one(ImmInstance, Type, init) ->
    Shrinkers = get_shrinkers(Type),
    shrink_one(ImmInstance, Type, {shrinker,Shrinkers,init});
shrink_one(_ImmInstance, _Type, {shrinker,[],init}) ->
    {[], done};
shrink_one(ImmInstance, Type, {shrinker,[_Shrinker | Rest],done}) ->
    shrink_one(ImmInstance, Type, {shrinker,Rest,init});
shrink_one(ImmInstance, Type, {shrinker,Shrinkers,State}) ->
    [Shrinker | _Rest] = Shrinkers,
    {NewImmInstances,NewState} = Shrinker(ImmInstance, Type, State),
    {NewImmInstances, {shrinker,Shrinkers,NewState}};
shrink_one(ImmInstance, Type, {shrunk,N,{shrinker,Shrinkers,State}}) ->
    shrink_one(ImmInstance, Type, {shrinker,Shrinkers,{shrunk,N,State}}).

-spec get_shrinkers(proper_types:type()) -> [shrinker()].
get_shrinkers(Type) ->
    case proper_types:find_prop(noshrink, Type) of
	{ok, true} ->
	    [];
	_ ->
	    CustomShrinkers =
		case proper_types:find_prop(shrinkers, Type) of
		    {ok, Shrinkers} -> Shrinkers;
		    error           -> []
		end,
	    StandardShrinkers =
		case proper_types:get_prop(kind, Type) of
		    basic ->
			[];
		    wrapper ->
			[fun alternate_shrinker/3, fun unwrap_shrinker/3];
		    constructed ->
			[fun parts_shrinker/3, fun recursive_shrinker/3];
		    semi_opaque ->
			[fun split_shrinker/3, fun remove_shrinker/3,
			 fun elements_shrinker/3];
		    opaque ->
			[fun split_shrinker/3, fun remove_shrinker/3,
			 fun elements_shrinker/3]
		end,
	    CustomShrinkers ++ StandardShrinkers
    end.


%%------------------------------------------------------------------------------
%% Non-opaque type shrinkers
%%------------------------------------------------------------------------------

-spec alternate_shrinker(proper_gen:imm_instance(), proper_types:type(),
			 state()) -> {[proper_gen:imm_instance()],state()}.
%% we stop at the smaller alternative shrinker
%% TODO: 'is_raw_type' check?
alternate_shrinker(Instance, Type, init) ->
    Choices = proper_types:unwrap(Type),
    union_first_choice_shrinker(Instance, Choices, init);
alternate_shrinker(_Instance, _Type, _State) ->
    {[], done}.

-spec unwrap_shrinker(proper_gen:imm_instance(), proper_types:type(),
		      state()) -> {[proper_gen:imm_instance()],state()}.
unwrap_shrinker(Instance, Type, init) ->
    Choices = proper_types:unwrap(Type),
    union_recursive_shrinker(Instance, Choices, init);
unwrap_shrinker(Instance, _Type, State) ->
    union_recursive_shrinker(Instance, [], State).

-spec parts_shrinker(proper_gen:imm_instance(), proper_types:type(), state()) ->
	  {[proper_gen:imm_instance()],state()}.
%% TODO: move some of the generation code in the proper_gen module
parts_shrinker(Instance = {'$used',_ImmParts,_ImmInstance}, Type, init) ->
    PartsType = proper_types:get_prop(parts_type, Type),
    parts_shrinker(Instance, Type, {parts,PartsType,dummy,init});
parts_shrinker(_CleanInstance, _Type, init) ->
    {[], done};
parts_shrinker(_Instance, _Type, {parts,_PartsType,_Lookup,done}) ->
    {[], done};
parts_shrinker({'$used',ImmParts,ImmInstance}, Type,
	       {parts,PartsType,_Lookup,PartsState}) ->
    {NewImmParts,NewPartsState} = shrink_one(ImmParts, PartsType, PartsState),
    Combine = proper_types:get_prop(combine, Type),
    DirtyNewInstances =
	[try_combine(P, ImmInstance, PartsType, Combine) || P <- NewImmParts],
    NotError = fun(X) ->
		   case X of
		       {'$used',_,'$cant_generate'} -> false;
		       _                            -> true
		   end
	       end,
    {NewInstances,NewLookup} = filter(NotError, DirtyNewInstances),
    {NewInstances, {parts,PartsType,NewLookup,NewPartsState}};
parts_shrinker(Instance, Type,
	       {shrunk,N,{parts,PartsType,Lookup,PartsState}}) ->
    ActualN = lists:nth(N, Lookup),
    parts_shrinker(Instance, Type,
		   {parts,PartsType,dummy,{shrunk,ActualN,PartsState}}).

-spec filter(fun((T) -> boolean()), [T]) -> {[T],[position()]}.
filter(Pred, List) ->
    filter_tr(Pred, List, [], 1, []).

-spec filter_tr(fun((T) -> boolean()), [T], [T], position(), [position()]) ->
	  {[T],[position()]}.
filter_tr(_Pred, [], Result, _Pos, Lookup) ->
    {lists:reverse(Result), lists:reverse(Lookup)};
filter_tr(Pred, [X | Rest], Result, Pos, Lookup) ->
    case Pred(X) of
	true ->
	    filter_tr(Pred, Rest, [X | Result], Pos + 1, [Pos | Lookup]);
	false ->
	    filter_tr(Pred, Rest, Result, Pos + 1, Lookup)
    end.

-spec try_combine(proper_gen:imm_instance(), proper_gen:imm_instance(),
		  proper_types:type(), proper_gen:combine_fun()) ->
	  proper_gen:imm_instance().
try_combine(ImmParts, OldImmInstance, PartsType, Combine) ->
    case proper_arith:surely(proper_types:is_instance(ImmParts, PartsType)) of
	true ->
	    Parts = proper_gen:clean_instance(ImmParts),
	    ImmInstance = Combine(Parts),
	    case proper_types:is_raw_type(ImmInstance) of
		true ->
		    InnerType = proper_types:cook_outer(ImmInstance),
		    %% TODO: special case if the immediately internal is a LET?
		    %% TODO: more specialized is_instance check here
		    case proper_arith:surely(proper_types:is_instance(
			     OldImmInstance, InnerType)) of
			true ->
			    {'$used',ImmParts,OldImmInstance};
			false ->
			    %% TODO: return more than one? then we must flatten
			    NewImmInstance = proper_gen:generate(InnerType),
			    {'$used',ImmParts,NewImmInstance}
		    end;
		false ->
		    {'$used',ImmParts,ImmInstance}
	    end;
	false ->
	    {'$used',dummy,'$cant_generate'}
    end.

-spec recursive_shrinker(proper_gen:imm_instance(), proper_types:type(),
			 state()) -> {[proper_gen:imm_instance()],state()}.
recursive_shrinker(Instance = {'$used',ImmParts,_ImmInstance}, Type, init) ->
    Combine = proper_types:get_prop(combine, Type),
    Parts = proper_gen:clean_instance(ImmParts),
    ImmInstance = Combine(Parts),
    case proper_types:is_raw_type(ImmInstance) of
	true ->
	    InnerType = proper_types:cook_outer(ImmInstance),
	    recursive_shrinker(Instance, Type, {inner,InnerType,init});
	false ->
	    {[], done}
    end;
recursive_shrinker(_CleanInstance, _Type, init) ->
    {[], done};
recursive_shrinker(_Instance, _Type, {inner,_InnerType,done}) ->
    {[], done};
recursive_shrinker({'$used',ImmParts,ImmInstance}, _Type,
		   {inner,InnerType,InnerState}) ->
    {NewImmInstances,NewInnerState} =
	shrink_one(ImmInstance, InnerType, InnerState),
    NewInstances = [{'$used',ImmParts,I} || I <- NewImmInstances],
    {NewInstances, {inner,InnerType,NewInnerState}};
recursive_shrinker(Instance, Type, {shrunk,N,{inner,InnerType,InnerState}}) ->
    recursive_shrinker(Instance, Type, {inner,InnerType,{shrunk,N,InnerState}}).


%%------------------------------------------------------------------------------
%% Opaque type shrinkers
%%------------------------------------------------------------------------------

-spec split_shrinker(proper_gen:instance(), proper_types:type(), state()) ->
	  {[proper_gen:instance()],state()}.
split_shrinker(Instance, Type, init) ->
    case {proper_types:find_prop(split, Type),
	  proper_types:find_prop(get_length, Type),
	  proper_types:find_prop(join, Type)} of
	{error, _, _} ->
	    {[], done};
	{{ok,_Split}, error, _} ->
	    split_shrinker(Instance, Type, no_pos);
	{{ok,_Split}, {ok,GetLength}, {ok,_Join}} ->
	    split_shrinker(Instance, Type, {slices,2,GetLength(Instance)})
    end;
split_shrinker(Instance, Type, no_pos) ->
    Split = proper_types:get_prop(split, Type),
    {Split(Instance), done};
split_shrinker(Instance, Type, {shrunk,done}) ->
    split_shrinker(Instance, Type, no_pos);
%% implementation of the ddmin algorithm, but stopping before the granularity
%% reaches 1, since we run a 'remove' shrinker after this
%% TODO: on success, start over with the whole testcase or keep removing slices?
split_shrinker(Instance, Type, {slices,N,Len}) ->
    case Len < 2 * N of
	true ->
	    {[], done};
	false ->
	    {SmallSlices,BigSlices} = slice(Instance, Type, N, Len),
	    {SmallSlices ++ BigSlices, {slices,2*N,Len}}
    end;
split_shrinker(Instance, Type, {shrunk,Pos,{slices,DoubleN,_Len}}) ->
    N = DoubleN div 2,
    GetLength = proper_types:get_prop(get_length, Type),
    case Pos =< N of
	true ->
	    split_shrinker(Instance, Type, {slices,2,GetLength(Instance)});
	false ->
	    split_shrinker(Instance, Type, {slices,N-1,GetLength(Instance)})
    end.

-spec slice(proper_gen:instance(), proper_types:type(), pos_integer(),
	    length()) -> {[proper_gen:instance()], [proper_gen:instance()]}.
slice(Instance, Type, Slices, Len) ->
    BigSlices = Len rem Slices,
    SmallSlices = Slices - BigSlices,
    SmallSliceLen = Len div Slices,
    BigSliceLen = SmallSliceLen + 1,
    BigSliceTotal = BigSlices * BigSliceLen,
    WhereToSlice =
	[{1 + X * BigSliceLen, BigSliceLen}
	 || X <- lists:seq(0, BigSlices - 1)] ++
	[{BigSliceTotal + 1 + X * SmallSliceLen, SmallSliceLen}
	 || X <- lists:seq(0, SmallSlices - 1)],
    lists:unzip([take_slice(Instance, Type, From, SliceLen)
		 || {From,SliceLen} <- WhereToSlice]).

-spec take_slice(proper_gen:instance(), proper_types:type(), pos_integer(),
		 length()) -> {proper_gen:instance(), proper_gen:instance()}.
take_slice(Instance, Type, From, SliceLen) ->
    Split = proper_types:get_prop(split, Type),
    Join = proper_types:get_prop(join, Type),
    {Front,ImmBack} = Split(From - 1, Instance),
    {Slice,Back} = Split(SliceLen, ImmBack),
    {Slice, Join(Front, Back)}.

-spec remove_shrinker(proper_gen:instance(), proper_types:type(), state()) ->
	  {[proper_gen:instance()], state()}.
%% TODO: try removing more than one elemnent: 2,4,... or 2,3,... - when to stop?
remove_shrinker(Instance, Type, init) ->
    case {proper_types:find_prop(get_indices, Type),
	  proper_types:find_prop(remove, Type)} of
	{{ok,_GetIndices}, {ok,_Remove}} ->
	    remove_shrinker(Instance, Type,
			    {shrunk,1,{indices,ordsets:from_list([]),dummy}});
	_ ->
	    {[], done}
    end;
remove_shrinker(_Instance, _Type, {indices,_Checked,[]}) ->
    {[], done};
remove_shrinker(Instance, Type, {indices,Checked,[Index | Rest]}) ->
    Remove = proper_types:get_prop(remove, Type),
    {[Remove(Index, Instance)],
     {indices,ordsets:add_element(Index, Checked),Rest}};
remove_shrinker(Instance, Type, {shrunk,1,{indices,Checked,_ToCheck}}) ->
    %% TODO: normally, indices wouldn't be expected to change for the remaining
    %%       elements, but this happens for lists, so we'll just avoid
    %%       re-checking any indices we have already tried (even though these
    %%       might correspond to new elements now - at least they don't in the
    %%       case of lists)
    %% TODO: ordsets are used to ensure efficiency, but the ordsets module
    %%       compares elements with == instead of =:=, that could cause us to
    %%       miss some elements in some cases
    GetIndices = proper_types:get_prop(get_indices, Type),
    Indices = ordsets:from_list(GetIndices(Instance)),
    NewToCheck = ordsets:subtract(Indices, Checked),
    remove_shrinker(Instance, Type, {indices,Checked,NewToCheck}).

-spec elements_shrinker(proper_gen:instance(), proper_types:type(), state()) ->
	  {[proper_gen:instance()],state()}.
%% TODO: is it safe to assume that all functions and the indices will not change
%%	 after any update?
%% TODO: shrink many elements concurrently?
elements_shrinker(Instance, Type, init) ->
    case {proper_types:find_prop(get_indices, Type),
	  proper_types:find_prop(retrieve, Type),
	  proper_types:find_prop(update, Type)} of
	{{ok,GetIndices}, {ok,Retrieve}, {ok,_Update}} ->
	    GetElemType =
		case proper_types:find_prop(internal_type, Type) of
		    {ok,RawInnerType} ->
			InnerType = proper_types:cook_outer(RawInnerType),
			fun(_I) -> InnerType end;
		    error ->
			InnerTypes =
			    proper_types:get_prop(internal_types, Type),
			fun(I) -> Retrieve(I, InnerTypes) end
		end,
	    Indices = GetIndices(Instance),
	    elements_shrinker(Instance, Type, {inner,Indices,GetElemType,init});
	_ ->
	    {[], done}
    end;
elements_shrinker(_Instance, _Type,
		  {inner,[],_GetElemType,init}) ->
    {[], done};
elements_shrinker(Instance, Type,
		  {inner,[_Index | Rest],GetElemType,done}) ->
    elements_shrinker(Instance, Type, {inner,Rest,GetElemType,init});
elements_shrinker(Instance, Type,
		  {inner,Indices = [Index | _Rest],GetElemType,InnerState}) ->
    Retrieve = proper_types:get_prop(retrieve, Type),
    Update = proper_types:get_prop(update, Type),
    Elem = Retrieve(Index, Instance),
    InnerType = GetElemType(Index),
    {NewImmElems,NewInnerState} = shrink_one(Elem, InnerType, InnerState),
    NewElems =
	case proper_types:get_prop(kind, Type) of
	    opaque -> [proper_gen:clean_instance(E) || E <- NewImmElems];
	    _      -> NewImmElems
	end,
    NewInstances = [Update(Index, E, Instance) || E <- NewElems],
    {NewInstances, {inner,Indices,GetElemType,NewInnerState}};
elements_shrinker(Instance, Type,
		  {shrunk,N,{inner,Indices,GetElemType,InnerState}}) ->
    elements_shrinker(Instance, Type,
		      {inner,Indices,GetElemType,{shrunk,N,InnerState}}).


%%------------------------------------------------------------------------------
%% Custom shrinkers
%%------------------------------------------------------------------------------

-spec number_shrinker(number(), proper_arith:extnum(), proper_arith:extnum(),
		      state()) -> {[number()],state()}.
number_shrinker(X, Low, High, init) ->
    {Target,Inc,OverLimit} = find_target(X, Low, High),
    case X =:= Target of
	true  -> {[], done};
	false -> {[Target], {inc,Target,Inc,OverLimit}}
    end;
number_shrinker(_X, _Low, _High, {inc,Last,Inc,OverLimit}) ->
    NewLast = Inc(Last),
    case OverLimit(NewLast) of
	true  -> {[], done};
	false -> {[NewLast], {inc,NewLast,Inc,OverLimit}}
    end;
number_shrinker(_X, _Low, _High, {shrunk,_Pos,_State}) ->
    {[], done}.

-spec find_target(number(), number(), number()) ->
	  {number(),fun((number()) -> number()),fun((number()) -> boolean())}.
find_target(X, Low, High) ->
    case {proper_arith:le(Low,0), proper_arith:le(0,High)} of
	{false, _} ->
	    Limit = find_limit(X, Low, High, High),
	    {Low, fun(Y) -> Y + 1 end, fun(Y) -> Y > Limit end};
	{true,false} ->
	    Limit = find_limit(X, Low, High, Low),
	    {High, fun(Y) -> Y - 1 end, fun(Y) -> Y < Limit end};
	{true,true} ->
	    Sign = sign(X),
	    OverLimit =
		case X >= 0 of
		    true ->
			Limit = find_limit(X, Low, High, High),
			fun(Y) -> Y > Limit end;
		    false ->
			Limit = find_limit(X, Low, High, Low),
			fun(Y) -> Y < Limit end
		end,
	    {zero(X), fun(Y) -> Y + Sign end, OverLimit}
    end.

-spec find_limit(number(), number(), number(), number()) -> number().
find_limit(X, Low, High, FallBack) ->
    case proper_arith:le(Low, X) andalso proper_arith:le(X, High) of
	true  -> X;
	false -> FallBack
    end.

-spec sign(number()) -> number().
sign(X) ->
    if
	X > 0 -> 1;
	X < 0 -> -1;
	true  -> zero(X)
    end.

-spec zero(number()) -> number().
zero(X) when is_integer(X) -> 0;
zero(X) when is_float(X)   -> 0.0.

-spec union_first_choice_shrinker(proper_gen:instance(), [proper_types:type()],
				  state()) -> {[proper_gen:instance()],state()}.
%% TODO: just try first choice?
%% TODO: do this incrementally?
union_first_choice_shrinker(Instance, Choices, init) ->
    case first_plausible_choice(Instance, Choices) of
	none ->
	    {[],done};
	{N,_Type} ->
	    %% TODO: some kind of constraints test here?
	    {[X || X <- [proper_gen:generate(T)
			 || T <- lists:sublist(Choices, N - 1)],
		   X =/= '$cant_generate'],
	     done}
    end;
union_first_choice_shrinker(_Instance, _Choices, {shrunk,_Pos,done}) ->
    {[], done}.

-spec union_recursive_shrinker(proper_gen:instance(), [proper_types:type()],
			       state()) -> {[proper_gen:instance()],state()}.
union_recursive_shrinker(Instance, Choices, init) ->
    case first_plausible_choice(Instance, Choices) of
	none ->
	    {[],done};
	{N,Type} ->
	    union_recursive_shrinker(Instance, Choices, {inner,N,Type,init})
    end;
union_recursive_shrinker(_Instance, _Choices, {inner,_N,_Type,done}) ->
    {[],done};
union_recursive_shrinker(Instance, _Choices, {inner,N,Type,InnerState}) ->
    {NewInstances,NewInnerState} = shrink_one(Instance, Type, InnerState),
    {NewInstances, {inner,N,Type,NewInnerState}};
union_recursive_shrinker(Instance, Choices,
			 {shrunk,Pos,{inner,N,Type,InnerState}}) ->
    union_recursive_shrinker(Instance, Choices,
			     {inner,N,Type,{shrunk,Pos,InnerState}}).

-spec first_plausible_choice(proper_gen:imm_instance(),
			     [proper_types:type()]) ->
	  {position(),proper_types:type()} | 'none'.
first_plausible_choice(Instance, Choices) ->
    first_plausible_choice_tr(Instance, Choices, 1).

-spec first_plausible_choice_tr(proper_gen:imm_instance(),
				[proper_types:type()], position()) ->
	  {position(),proper_types:type()} | 'none'.
first_plausible_choice_tr(_Instance, [], _Pos) ->
    none;
first_plausible_choice_tr(Instance, [Type | Rest], Pos) ->
    case proper_arith:surely(proper_types:is_instance(Instance, Type)) of
	true  -> {Pos,Type};
	false -> first_plausible_choice_tr(Instance, Rest, Pos + 1)
    end.