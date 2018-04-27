------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2018, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Interfaces.C;            use Interfaces.C;
with Interfaces.C.Extensions; use Interfaces.C.Extensions;

with Errout;   use Errout;
with Eval_Fat; use Eval_Fat;
with Lib;      use Lib;
with Nlists;   use Nlists;
with Sem_Aggr; use Sem_Aggr;
with Sem_Eval; use Sem_Eval;
with Sem_Util; use Sem_Util;
with Sem_Aux;  use Sem_Aux;
with Sinfo;    use Sinfo;
with Snames;   use Snames;
with Stand;    use Stand;
with Stringt;  use Stringt;
with Uintp;    use Uintp;
with Urealp;   use Urealp;

with LLVM.Core;     use LLVM.Core;
with LLVM.Types;    use LLVM.Types;

with GNATLLVM.Arrays;       use GNATLLVM.Arrays;
with GNATLLVM.Blocks;       use GNATLLVM.Blocks;
with GNATLLVM.Conditionals; use GNATLLVM.Conditionals;
with GNATLLVM.DebugInfo;    use GNATLLVM.DebugInfo;
with GNATLLVM.GLValue;      use GNATLLVM.GLValue;
with GNATLLVM.Records;      use GNATLLVM.Records;
with GNATLLVM.Types;        use GNATLLVM.Types;
with GNATLLVM.Subprograms;  use GNATLLVM.Subprograms;
with GNATLLVM.Utils;        use GNATLLVM.Utils;

package body GNATLLVM.Compile is

   --  Note: in order to find the right LLVM instruction to generate,
   --  you can compare with what Clang generates on corresponding C or C++
   --  code. This can be done online via http://ellcc.org/demo/index.cgi

   --  See also DragonEgg sources for comparison on how GCC nodes are converted
   --  to LLVM nodes: http://llvm.org/svn/llvm-project/dragonegg/trunk

   function Emit_Attribute_Reference
     (N : Node_Id; LValue : Boolean) return GL_Value
     with Pre  => Nkind (N) = N_Attribute_Reference,
          Post => Present (Emit_Attribute_Reference'Result);
   --  Helper for Emit_Expression: handle N_Attribute_Reference nodes

   function Is_Zero_Aggregate (Src_Node : Node_Id) return Boolean
     with Pre => Nkind_In (Src_Node, N_Aggregate, N_Extension_Aggregate)
                 and then Is_Others_Aggregate (Src_Node);
   --  Helper for Emit_Assignment: say whether this is an aggregate of all
   --  zeros.

   procedure Emit_Assignment
     (LValue                    : GL_Value;
      Orig_E                    : Node_Id;
      E_Value                   : GL_Value;
      Forwards_OK, Backwards_OK : Boolean)
     with Pre => Present (LValue) or else Present (Orig_E);
   --  Helper for Emit: Copy the value of the expression E to LValue
   --  with the specified destination and expression types.

   function Emit_Literal (N : Node_Id) return GL_Value
     with Pre  => Present (N),
          Post => Present (Emit_Literal'Result);

   function Is_Parent_Of (T_Need, T_Have : Entity_Id) return Boolean
     with Pre => Is_Type (T_Need) and then Is_Type (T_Have);
   --  True if T_Have is a parent type of T_Need

   function Emit_LValue_Internal (Node : Node_Id) return GL_Value
     with Pre  => Present (Node),
          Post => Present (Emit_LValue_Internal'Result);
   --  Called by Emit_LValue to walk the tree saving values

   function Emit_LValue_Main (Node : Node_Id) return GL_Value
     with Pre  => Present (Node),
          Post => Present (Emit_LValue_Main'Result);
   --  Called by Emit_LValue_Internal to do the work at each level

   function Emit_Shift
     (Operation           : Node_Kind;
      LHS_Node, RHS_Node  : Node_Id) return GL_Value
     with Pre  => Operation in N_Op_Shift and then Present (LHS_Node)
                  and then Present (RHS_Node),
          Post => Present (Emit_Shift'Result);
   --  Helper for Emit_Expression: handle shift and rotate operations

   --  We save pairs of GNAT type and LLVM Value_T for each level of
   --  processing of an Emit_LValue so we can find it if we have a
   --  self-referential item (a discriminated record).

   package LValue_Pair_Table is new Table.Table
     (Table_Component_Type => GL_Value,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 5,
      Table_Name           => "LValue_Pair_Table");
   --  Table of intermediate results for Emit_LValue

   -----------------------
   -- Emit_Library_Item --
   -----------------------

   procedure Emit_Library_Item (U : Node_Id) is
      Prag : Node_Id;

   begin
      --  Ignore Standard and ASCII packages

      if Sloc (U) <= Standard_Location then
         return;
      end if;

      --  We assume there won't be any elaboration code for any unit and
      --  clear that flag if we're wrong.

      In_Main_Unit := In_Extended_Main_Code_Unit (U);
      if In_Main_Unit and then Nkind (Parent (U)) = N_Compilation_Unit then
         Set_Has_No_Elaboration_Code (Parent (U), True);
      end if;

      --  Process any pragmas and declarations preceding the unit

      Prag := First (Context_Items (Parent (U)));
      while Present (Prag) loop
         if Nkind (Prag) = N_Pragma then
            Emit (Prag);
         end if;

         Next (Prag);
      end loop;

      Emit_List (Declarations (Aux_Decls_Node (Parent (U))));

      --  Process the unit itself

      Emit (U);
   end Emit_Library_Item;

   ----------
   -- Emit --
   ----------

   procedure Emit (Node : Node_Id) is
   begin
      Set_Debug_Pos_At_Node (Node);
      if Library_Level
        and then (Nkind (Node) in N_Statement_Other_Than_Procedure_Call
                    or else Nkind (Node) in N_Subprogram_Call
                    or else Nkind (Node) = N_Handled_Sequence_Of_Statements
                    or else Nkind (Node) in N_Raise_xxx_Error
                    or else Nkind (Node) = N_Raise_Statement)
      then
         --  Append to list of statements to put in the elaboration procedure
         --  if in main unit, otherwise simply ignore the statement.

         if In_Main_Unit then
            Elaboration_Table.Append (Node);
         end if;

         return;
      end if;

      --  If not at library level and in dead code, start a new basic block
      --  for any code we emit.

      if not Library_Level and then Are_In_Dead_Code then
         Position_Builder_At_End (Create_Basic_Block ("dead-code"));
      end if;

      case Nkind (Node) is
         when N_Abstract_Subprogram_Declaration =>
            null;

         when N_Compilation_Unit =>
            Emit_List (Context_Items (Node));
            Emit_List (Declarations (Aux_Decls_Node (Node)));
            Emit (Unit (Node));
            Emit_List (Actions (Aux_Decls_Node (Node)));
            Emit_List (Pragmas_After (Aux_Decls_Node (Node)));

         when N_With_Clause =>
            null;

         when N_Use_Package_Clause =>
            null;

         when N_Package_Declaration =>
            Push_Lexical_Debug_Scope (Node);
            Emit (Specification (Node));
            Pop_Debug_Scope;

         when N_Package_Specification =>
            Push_Lexical_Debug_Scope (Node);
            Emit_List (Visible_Declarations (Node));
            Emit_List (Private_Declarations (Node));
            Pop_Debug_Scope;

            if Library_Level then
               Emit_Elab_Proc (Node, Empty, Parent (Parent (Node)), "s");
            end if;

         when N_Package_Body =>

            --  Skip generic packages

            if Ekind (Unique_Defining_Entity (Node)) in Generic_Unit_Kind then
               return;
            end if;

            declare
               Stmts : constant Node_Id := Handled_Statement_Sequence (Node);

            begin
               --  Always process declarations

               Push_Lexical_Debug_Scope (Node);
               Emit_List (Declarations (Node));

               --  If we're at library level and our parent is an
               --  N_Compilation_Unit, make an elab proc and put the
               --  statements there.  Otherwise, emit them, which may add
               --  them to the elaboration table (if we're not at library
               --  level).

               if Library_Level
                 and then Nkind (Parent (Node)) = N_Compilation_Unit
               then
                  Emit_Elab_Proc (Node, Stmts, Parent (Node), "b");
               elsif Present (Stmts) then
                  Emit (Stmts);
               end if;

               Pop_Debug_Scope;
            end;

         when N_Subprogram_Body =>

            --  Skip generic subprograms

            if Present (Corresponding_Spec (Node))
              and then (Ekind (Corresponding_Spec (Node))
                          in Generic_Subprogram_Kind)
            then
               null;

            --  If we are processing only declarations, do not emit a
            --  subprogram body: just declare this subprogram and add it to
            --  the environment.

            elsif not In_Main_Unit then
               Discard (Emit_Subprogram_Decl (Get_Acting_Spec (Node)));

            else
               Emit_Subprogram_Body (Node);
            end if;

         when N_Subprogram_Declaration =>
            declare
               Subp : constant Entity_Id := Unique_Defining_Entity (Node);

            begin
               --  Ignore intrinsic subprogram as calls to those will
               --  be expanded.

               if Convention (Subp) = Convention_Intrinsic
                 or else Is_Intrinsic_Subprogram (Subp)
               then
                  null;
               else
                  Discard (Emit_Subprogram_Decl (Specification (Node)));
               end if;
            end;

         when N_Handled_Sequence_Of_Statements =>
            Start_Block_Statements (At_End_Proc (Node),
                                    Exception_Handlers (Node));
            Emit_List (Statements (Node));

         when N_Raise_Statement =>
            Emit_LCH_Call (Node);

         when N_Raise_xxx_Error =>

            --  See if this Raise is really a goto due to having a label on
            --  the appropriate stack.

            declare
               Label_Ent : constant Entity_Id :=
                 Get_Exception_Goto_Entry (Nkind (Node));
               BB_Next   : Basic_Block_T;

            begin
               if Present (Label_Ent) then
                  if Present (Condition (Node)) then
                     BB_Next := Create_Basic_Block;
                     Emit_If_Cond
                       (Condition (Node), Get_Label_BB (Label_Ent), BB_Next);
                     Position_Builder_At_End (BB_Next);
                  else
                     Build_Br (Get_Label_BB (Label_Ent));
                  end if;

                  return;
               end if;
            end;

            if Present (Condition (Node)) then
               declare
                  BB_Then : constant Basic_Block_T :=
                    Create_Basic_Block ("raise");
                  BB_Next : constant Basic_Block_T := Create_Basic_Block;

               begin
                  Emit_If_Cond (Condition (Node), BB_Then, BB_Next);
                  Position_Builder_At_End (BB_Then);
                  Emit_LCH_Call (Node);
                  Build_Br (BB_Next);
                  Position_Builder_At_End (BB_Next);
               end;
            else
               Emit_LCH_Call (Node);
            end if;

         when N_Object_Declaration | N_Exception_Declaration =>
            --  Object declarations are variables either allocated on the stack
            --  (local) or global.

            --  If we are processing only declarations, only declare the
            --  corresponding symbol at the LLVM level and add it to the
            --  environment.

            declare
               Def_Ident : constant Node_Id := Defining_Identifier (Node);
               T         : constant Entity_Id := Full_Etype (Def_Ident);
               LLVM_Type : Type_T;
               LLVM_Var  : GL_Value;
               Value     : GL_Value := No_GL_Value;

            begin
               --  Nothing to do if this is a debug renaming type

               if T = Standard_Debug_Renaming_Type then
                  return;
               end if;

               --  Ignore deferred constant definitions without address
               --  Clause Since They Are Processed Fully in The Front-end.
               --  If No_Initialization is set, this is not a deferred
               --  constant but a constant whose value is built manually.
               --  And constants that are renamings are handled like
               --  variables.

               if Ekind (Def_Ident) = E_Constant
                 and then Present (Full_View (Def_Ident))
                 and then No (Address_Clause (Def_Ident))
                 and then not No_Initialization (Node)
                 and then No (Renamed_Object (Def_Ident))
               then
                  return;
               end if;

               --  Handle top-level declarations or ones that need to be
               --  treated that way.  If we're processing elaboration
               --  code, we've already made the item and need do nothing
               --  special if it's to be statically allocated.

               if Library_Level
                 or else (Is_Statically_Allocated (Def_Ident)
                            and then not Special_Elaboration_Code)
               then
                  --  ??? Will only work for objects of static sizes

                  LLVM_Type := Create_Type (T);
                  pragma Assert (not Is_Dynamic_Size (T));

                  if Present (Address_Clause (Def_Ident)) then
                     LLVM_Type := Pointer_Type (LLVM_Type, 0);
                  end if;

                  LLVM_Var := Add_Global (T, Get_Ext_Name (Def_Ident));
                  if not Library_Level then
                     Set_Linkage (LLVM_Var, Internal_Linkage);
                  end if;

                  Set_Value (Def_Ident, LLVM_Var);

                  if In_Main_Unit then

                     --  ??? This code is probably wrong, but is rare enough
                     --  that we'll worry about it later.

                     if Present (Address_Clause (Def_Ident)) then
                        Set_Initializer
                          (LLVM_Var,
                           Emit_Expression
                             (Expression (Address_Clause (Def_Ident))));
                        --  ??? Should also take Expression (Node) into account

                     else
                        if Is_Imported (Def_Ident) then
                           Set_Linkage (LLVM_Var, External_Linkage);
                        end if;

                        --  Take Expression (Node) into account

                        if Present (Expression (Node))
                          and then not
                            (Nkind (Node) = N_Object_Declaration
                             and then No_Initialization (Node))
                        then
                           if Compile_Time_Known_Value (Expression (Node)) then
                              Set_Initializer
                                (LLVM_Var,
                                 Build_Type_Conversion (Expression (Node), T));
                           else
                              Elaboration_Table.Append (Node);

                              if not Is_Imported (Def_Ident) then
                                 Set_Initializer (LLVM_Var, Const_Null (T));
                              end if;
                           end if;
                        elsif not Is_Imported (Def_Ident) then
                           Set_Initializer (LLVM_Var, Const_Null (T));
                        end if;
                     end if;
                  else
                     Set_Linkage (LLVM_Var, External_Linkage);
                  end if;

               else
                  if Present (Expression (Node))
                    and then not
                      (Nkind (Node) = N_Object_Declaration
                       and then No_Initialization (Node))
                  then
                     Value := Emit_Expression (Expression (Node));
                  end if;

                  if Special_Elaboration_Code then
                     LLVM_Var := Get_Value (Def_Ident);

                  elsif Present (Address_Clause (Def_Ident)) then
                        LLVM_Var := Int_To_Ref
                          (Emit_Expression
                             (Expression (Address_Clause (Def_Ident))),
                           T, Get_Name (Def_Ident));
                  else
                     LLVM_Var := Allocate_For_Type
                       (T, V => Value, Name => Get_Name (Def_Ident));

                  end if;

                  Set_Value (Def_Ident, LLVM_Var);

                  if Present (Value) then
                     Emit_Assignment (LLVM_Var, Empty, Value, True, True);
                  end if;
               end if;
            end;

         when N_Use_Type_Clause =>
            null;

         when N_Object_Renaming_Declaration =>
            declare
               Def_Ident : constant Node_Id   := Defining_Identifier (Node);
               TE        : constant Entity_Id := Full_Etype (Def_Ident);
               Obj_Name  : constant String    := Get_Name (Def_Ident);
               LLVM_Var  : constant GL_Value  :=
                 Need_LValue (Emit_LValue (Name (Node)), TE, Name => Obj_Name);

            begin
               Set_Value (Def_Ident, LLVM_Var);
            end;

         when N_Subprogram_Renaming_Declaration =>
            --  Nothing is needed except for debugging information.
            --  Skip it for now???
            --  Note that in any case, we should skip Intrinsic subprograms

            null;

         when N_Implicit_Label_Declaration =>
            --  Don't do anything here in case this label isn't actually
            --  used as a label.  In that case, the basic block we create
            --  here will be empty, which LLVM doesn't allow.  This can't
            --  occur for user-defined labels, but can occur with some
            --  labels placed by the front end.  Instead, lazily create
            --  the basic block where it's placed or when its the target
            --  of a goto.
            null;

         when N_Assignment_Statement =>
            Emit_Assignment (Emit_LValue (Name (Node)), Expression (Node),
                             No_GL_Value, Forwards_OK (Node),
                             Backwards_OK (Node));

         when N_Procedure_Call_Statement =>
            Discard (Emit_Call (Node));

         when N_Null_Statement =>
            null;

         when N_Label =>
            Discard (Enter_Block_With_Node (Node));

         when N_Goto_Statement =>
            Build_Br (Get_Label_BB (Entity (Name (Node))));

         when N_Exit_Statement =>
            declare
               Exit_BB : constant Basic_Block_T :=
                 Get_Exit_Point (Name (Node));
               Next_BB : Basic_Block_T;

            begin
               if Present (Condition (Node)) then
                  Next_BB := Create_Basic_Block ("loop-after-exit");
                  Emit_If_Cond (Condition (Node), Exit_BB, Next_BB);
                  Position_Builder_At_End (Next_BB);
               else
                  Build_Br (Exit_BB);
               end if;

            end;

         when N_Simple_Return_Statement =>
            if Present (Expression (Node)) then

               --  If there's a parameter for the address to which to copy
               --  the return value, do the copy instead of returning the
               --  value.

               if Present (Return_Address_Param) then
                  Emit_Assignment (Return_Address_Param, Expression (Node),
                                   No_GL_Value, True, True);
                  Build_Ret_Void;

               else
                  Build_Ret
                    (Build_Type_Conversion
                       (Expression (Node),
                        Full_Etype (Node_Enclosing_Subprogram (Node))));
               end if;

            else
               Build_Ret_Void;
            end if;

         when N_If_Statement =>
            Emit_If (Node);

         when N_Loop_Statement =>
            declare
               Loop_Identifier : constant Entity_Id :=
                 (if Present (Identifier (Node))
                  then Entity (Identifier (Node)) else Empty);
               Iter_Scheme     : constant Node_Id := Iteration_Scheme (Node);
               Is_Mere_Loop    : constant Boolean := not Present (Iter_Scheme);
               Is_For_Loop     : constant Boolean :=
                 not Is_Mere_Loop
                 and then Present (Loop_Parameter_Specification (Iter_Scheme));

               --  The general format for a loop is:
               --    INIT;
               --    while COND loop
               --       STMTS;
               --       ITER;
               --    end loop;
               --    NEXT:
               --  Each step has its own basic block. When a loop does not need
               --  one of these steps, just alias it with another one.

               BB_Cond           : Basic_Block_T :=
                 (if not Is_For_Loop
                  then Enter_Block_With_Node (Empty)
                  else Create_Basic_Block ("loop-cond"));
               --  If this is not a FOR loop, there is no initialization: alias
               --  it with the COND block.

               BB_Stmts         : constant Basic_Block_T :=
                 (if Is_Mere_Loop or else Is_For_Loop
                  then BB_Cond else Create_Basic_Block ("loop-stmts"));
               --  If this is a mere loop or a For loop, there is no condition
               --  block: alias it with the STMTS block.

               BB_Iter          : Basic_Block_T :=
                 (if Is_For_Loop then Create_Basic_Block ("loop-iter")
                  else BB_Cond);
               --  If this is not a FOR loop, there is no iteration: alias it
               --  with the COND block, so that at the end of every STMTS, jump
               --  on ITER or COND.

               BB_Next          : constant Basic_Block_T :=
                   Create_Basic_Block ("loop-exit");
               --  The NEXT step contains no statement that comes from the
               --  loop: it is the exit point.

            begin

               --  First compile the iterative part of the loop: evaluation of
               --  the exit condition, etc.

               if not Is_Mere_Loop then
                  if not Is_For_Loop then

                     --  This is a WHILE loop: jump to the loop-body if the
                     --  condition evaluates to True, jump to the loop-exit
                     --  otherwise.

                     Position_Builder_At_End (BB_Cond);
                     Emit_If_Cond (Condition (Iter_Scheme), BB_Stmts, BB_Next);

                  else
                     --  This is a FOR loop

                     declare
                        Loop_Param_Spec : constant Node_Id :=
                          Loop_Parameter_Specification (Iter_Scheme);
                        Def_Ident       : constant Node_Id :=
                          Defining_Identifier (Loop_Param_Spec);
                        Reversed        : constant Boolean :=
                          Reverse_Present (Loop_Param_Spec);
                        Unsigned_Type   : constant Boolean :=
                          Is_Unsigned_Type (Full_Etype (Def_Ident));
                        Var_Type        : constant Entity_Id :=
                          Full_Etype (Def_Ident);
                        LLVM_Type       : Type_T;
                        LLVM_Var        : GL_Value;
                        Low, High       : GL_Value;

                     begin
                        --  Initialization block: create the loop variable and
                        --  initialize it.

                        Create_Discrete_Type (Var_Type, LLVM_Type, Low, High);
                        LLVM_Var := Allocate_For_Type
                          (Var_Type, Name => Get_Name (Def_Ident));
                        Set_Value (Def_Ident, LLVM_Var);
                        Store
                          ((if Reversed then High else Low), LLVM_Var);

                        --  Then go to the condition block if the range isn't
                        --  empty.

                        Build_Cond_Br (I_Cmp
                          ((if Unsigned_Type then Int_ULE else Int_SLE),
                           Low, High, "loop-entry-cond"),
                          BB_Cond, BB_Next);

                        BB_Cond := Create_Basic_Block ("loop-cond-iter");
                        Position_Builder_At_End (BB_Cond);
                        Build_Cond_Br (I_Cmp
                          (Int_EQ, Load (LLVM_Var),
                           (if Reversed then Low else High), "loop-iter-cond"),
                          BB_Next, BB_Iter);

                        --  After STMTS, stop if the loop variable was equal to
                        --  the "exit" bound. Increment/decrement it otherwise.

                        Position_Builder_At_End (BB_Iter);

                        declare
                           Iter_Prev_Value : constant GL_Value :=
                             Load (LLVM_Var);
                           One             : constant GL_Value :=
                             Const_Int (Var_Type, 1, False);
                           Iter_Next_Value : constant GL_Value :=
                             (if Reversed
                              then NSW_Sub
                                (Iter_Prev_Value, One, "next-loop-var")
                              else NSW_Add
                                (Iter_Prev_Value, One, "next-loop-var"));
                        begin
                           Store (Iter_Next_Value, LLVM_Var);
                        end;

                        Build_Br (BB_Stmts);

                        --  The ITER step starts at this special COND step

                        BB_Iter := BB_Cond;
                     end;
                  end if;
               end if;

               --  Finally, emit the body of the loop.  Save and restore
               --  the stack around that code, so we free any variables
               --  allocated each iteration.

               Position_Builder_At_End (BB_Stmts);
               Push_Block;
               Start_Block_Statements (Empty, No_List);
               Push_Loop (Loop_Identifier, BB_Next);
               Emit_List (Statements (Node));
               Set_Debug_Pos_At_Node (Node);
               Pop_Block;
               Pop_Loop;

               Build_Br (BB_Iter);
               Position_Builder_At_End (BB_Next);
            end;

         when N_Block_Statement =>
            Push_Lexical_Debug_Scope (Node);
            Push_Block;
            Emit_List (Declarations (Node));
            Emit (Handled_Statement_Sequence (Node));
            Set_Debug_Pos_At_Node (Node);
            Pop_Block;
            Pop_Debug_Scope;

         when N_Full_Type_Declaration
            | N_Subtype_Declaration
            | N_Incomplete_Type_Declaration
            | N_Private_Type_Declaration
            | N_Private_Extension_Declaration
           =>
            Discard
              (GNAT_To_LLVM_Type (Defining_Identifier (Node), True));

         when N_Freeze_Entity =>
            --  ??? Need to process Node itself

            Emit_List (Actions (Node));

         when N_Pragma =>
            case Get_Pragma_Id (Node) is
               --  ??? While we aren't interested in most of the pragmas,
               --  there are some we should look at (see
               --  trans.c:Pragma_to_gnu). But still, the "others" case is
               --  necessary.

               when others => null;
            end case;

         when N_Case_Statement =>
            Emit_Case (Node);

         when N_Body_Stub =>
            if Nkind_In (Node, N_Protected_Body_Stub, N_Task_Body_Stub) then
               raise Program_Error;
            end if;

            --  No action if the separate unit is not available

            if No (Library_Unit (Node)) then
               Error_Msg_N ("separate unit not available", Node);
            else
               Emit (Get_Body_From_Stub (Node));
            end if;

         --  Nodes we actually want to ignore, in many cases because they
         --  represent tings that are put elsewhere in the three (e.g,
         --  rep clauses).

         when N_Call_Marker
            | N_Empty
            | N_Enumeration_Representation_Clause
            | N_Enumeration_Type_Definition
            | N_Function_Instantiation
            | N_Freeze_Generic_Entity
            | N_Itype_Reference
            | N_Number_Declaration
            | N_Procedure_Instantiation
            | N_Validate_Unchecked_Conversion
            | N_Variable_Reference_Marker
            | N_Package_Instantiation
            | N_Package_Renaming_Declaration
            | N_Generic_Package_Declaration
            | N_Generic_Subprogram_Declaration
            | N_Record_Representation_Clause
            | N_At_Clause
           =>
            null;

         when N_Push_Constraint_Error_Label .. N_Pop_Storage_Error_Label =>
            Process_Push_Pop_xxx_Error_Label (Node);

         when N_Exception_Renaming_Declaration =>
            Set_Value
              (Defining_Identifier (Node), Get_Value (Entity (Name (Node))));

         when N_Attribute_Definition_Clause =>
            --  The only interesting case left after expansion is for Address
            --  clauses. We only deal with 'Address if the object has a Freeze
            --  node.

            --  ??? For now keep it simple and deal with this case in
            --  N_Object_Declaration.

            if Get_Attribute_Id (Chars (Node)) = Attribute_Address
              and then Present (Freeze_Node (Entity (Name (Node))))
            then
               null;
            end if;

         when others =>
            Error_Msg_N
              ("unhandled statement kind: `" &
               Node_Kind'Image (Nkind (Node)) & "`", Node);
      end case;
   end Emit;

   -----------------
   -- Emit_LValue --
   -----------------

   function Emit_LValue
     (Node : Node_Id; Clear : Boolean := True) return GL_Value is
   begin
      Set_Debug_Pos_At_Node (Node);

      --  When we start a new recursive call, we usualy free the entries
      --  from the last one.
      if Clear then
         LValue_Pair_Table.Set_Last (0);
      end if;

      return Emit_LValue_Internal (Node);
   end Emit_LValue;

   --------------------------
   -- Emit_LValue_Internal --
   --------------------------

   function Emit_LValue_Internal (Node : Node_Id) return GL_Value
   is
      Typ   : constant Entity_Id := Full_Etype (Node);
      Value : constant GL_Value := Need_LValue (Emit_LValue_Main (Node), Typ);

   begin
      --  If the object is not of void type, save the result in the
      --  pair table under the base type of the fullest view.

      if not Is_Subprogram_Type (Value) and then Ekind (Value) /= E_Void then
         LValue_Pair_Table.Append (Value);
      end if;

      return Value;
   end Emit_LValue_Internal;

   ----------------------
   -- Emit_LValue_Main --
   ----------------------

   function Emit_LValue_Main (Node : Node_Id) return GL_Value is
   begin
      case Nkind (Node) is
         when N_Identifier | N_Expanded_Name | N_Operator_Symbol |
           N_Defining_Identifier | N_Defining_Operator_Symbol =>
            declare
               Def_Ident : Entity_Id := Entity (Node);
               Typ       : Entity_Id := Full_Etype (Def_Ident);

            begin
               --  If this is a deferred constant, look at the private
               --  version.

               if Ekind (Def_Ident) = E_Constant
                 and then Present (Full_View (Def_Ident))
                 and then No (Address_Clause (Def_Ident))
               then
                  Def_Ident := Full_View (Def_Ident);
               end if;

               if Ekind (Def_Ident) in Subprogram_Kind then

                  --  If we are elaborating this for 'Access, we want the
                  --  actual subprogram type here, not the type of the return
                  --  value, which is what Typ is set to.

                  if Nkind (Parent (Node)) = N_Attribute_Reference
                    and then Is_Access_Type (Full_Etype (Parent (Node)))
                  then
                     Typ := Full_Designated_Type (Full_Etype (Parent (Node)));
                  end if;

                  if not Needs_Activation_Record (Typ) then
                     if Typ = Standard_Void_Type then
                        return Get_Value (Def_Ident);
                     else
                        return Convert_To_Access_To
                          (Get_Value (Def_Ident), Typ);
                     end if;
                  else
                     --  Return a callback, which is a pair: subprogram
                     --  code pointer and static link argument.

                     declare
                        Func   : constant GL_Value := Get_Value (Def_Ident);
                        S_Link : constant GL_Value := Get_Static_Link (Node);
                        Callback_Type : constant Type_T :=
                          Build_Struct_Type
                          ((1 => Type_Of (S_Link), 2 => Type_Of (S_Link)));
                        Result : constant GL_Value :=
                          Get_Undef_Ref (Callback_Type, Typ);

                     begin
                        return Insert_Value
                          (Insert_Value (Result, S_Link, 1),
                           Pointer_Cast (Func, S_Link), 0);
                     end;
                  end if;

               --  Handle entities in Standard and ASCII on the fly

               elsif Sloc (Def_Ident) <= Standard_Location then
                  declare
                     Var : constant GL_Value :=
                       Add_Global (Full_Etype (Def_Ident),
                                   Get_Ext_Name (Def_Ident));
                  begin
                     Set_Linkage (Var, External_Linkage);
                     Set_Value (Def_Ident, Var);
                     return Var;
                  end;
               else
                  return Get_Value (Def_Ident);
               end if;
            end;

         when N_Attribute_Reference =>
            return Emit_Attribute_Reference (Node, LValue => True);

         when N_Explicit_Dereference =>

            --  The result of evaluating Emit_Expression is the
            --  address of what we want and is an access type.  What
            --  we want here is a reference to our type, which should
            --  be the Designated_Type of Value.

            return Make_Reference (Emit_Expression (Prefix (Node)));

         when N_String_Literal =>
            declare
               V : constant GL_Value := Add_Global (Full_Etype (Node), "str");

            begin
               Set_Value (Node, V);
               Set_Initializer (V, Emit_Expression (Node));
               Set_Linkage (V, Private_Linkage);
               Set_Global_Constant (LLVM_Value (V), True);
               return V;
            end;

         when N_Selected_Component =>
            return Record_Field_Offset (Emit_LValue_Internal (Prefix (Node)),
                                        Entity (Selector_Name (Node)));

         when N_Indexed_Component =>
            return Get_Indexed_LValue (Expressions (Node),
                                       Emit_LValue_Internal (Prefix (Node)));

         when N_Slice =>
            return Get_Slice_LValue
              (Full_Etype (Node), Discrete_Range (Node),
               Emit_LValue_Internal (Prefix (Node)));

         when N_Unchecked_Type_Conversion | N_Type_Conversion |
           N_Qualified_Expression =>
            --  We have to mark that this is now to be treated as a new type.
            --  This matters if, e.g., the bounds of an array subtype change
            --  (see C46042A).

            return Convert_To_Access_To
              (Emit_LValue_Internal (Expression (Node)), Full_Etype (Node));

         when others =>
            --  If we have an arbitrary expression, evaluate it.  If it
            --  turns out to be a reference (e.g., if the size of our type
            --  is dynamic, we have no more work to do.  Otherwise, our caller
            --  will take care of storing it into a temporary.

            return Emit_Expression (Node);
      end case;
   end Emit_LValue_Main;

   -------------------------
   --  Add_To_LValue_List --
   -------------------------

   procedure Add_To_LValue_List (V : GL_Value) is
   begin
      LValue_Pair_Table.Append (V);
   end Add_To_LValue_List;

   ------------------
   -- Is_Parent_Of --
   ------------------

   function Is_Parent_Of (T_Need, T_Have : Entity_Id) return Boolean is
   begin
      --  If the two types are the same return True.  Likewise if
      --  T_Have has a parent different than itself and that and this
      --  relation holds for that.

      if T_Need = T_Have then
         return True;
      elsif Ekind (T_Have) = E_Record_Type
        and then Full_Etype (T_Have) /= T_Have
      then
         return Is_Parent_Of (T_Need, Full_Etype (T_Have));
      else
         return False;
      end if;

   end Is_Parent_Of;

   ------------------------
   -- Get_Matching_Value --
   ------------------------

   function Get_Matching_Value (T : Entity_Id) return GL_Value is
   begin
      --  Check in the opposite order of what we push.  We may, for example
      --  be finding the size of an object of that size, in which case the
      --  object will have been added last.

      for J in reverse 1 .. LValue_Pair_Table.Last loop
         if Is_Parent_Of (T_Need => Implementation_Base_Type (T),
                          T_Have => Implementation_Base_Type
                            (LValue_Pair_Table.Table (J).Typ))
         then
            return Convert_To_Access_To (LValue_Pair_Table.Table (J), T);
         end if;
      end loop;

      --  Should never get here and postcondition verifies

      return No_GL_Value;
   end Get_Matching_Value;

   ---------------------
   -- Emit_Expression --
   ---------------------

   function Emit_Expression (Node : Node_Id) return GL_Value is
      TE : constant Entity_Id := Full_Etype (Node);

   begin
      Set_Debug_Pos_At_Node (Node);
      if Nkind (Node) in N_Binary_Op then

         --  Use helper functions for comparisons and shifts; the rest by
         --  generating the appropriate LLVM IR directly.

         if Nkind (Node) in N_Op_Compare then
            return Emit_Comparison
              (Nkind (Node), Left_Opnd (Node), Right_Opnd (Node));
         elsif Nkind (Node) in N_Op_Shift then
            return Emit_Shift
              (Nkind (Node), Left_Opnd (Node), Right_Opnd (Node));
         end if;

         declare
            type Opf is access function
              (LHS, RHS : GL_Value; Name : String := "") return GL_Value;

            Left_Type  : constant Entity_Id := Full_Etype (Left_Opnd (Node));
            Right_Type : constant Entity_Id := Full_Etype (Right_Opnd (Node));
            Left_BT    : constant Entity_Id :=
              Implementation_Base_Type (Left_Type);
            Right_BT   : constant Entity_Id :=
              Implementation_Base_Type (Right_Type);
            LVal       : constant GL_Value  :=
              Build_Type_Conversion (Left_Opnd (Node), Left_BT);
            RVal       : constant GL_Value  :=
              Build_Type_Conversion (Right_Opnd (Node), Right_BT);
            FP         : constant Boolean   :=
              Is_Floating_Point_Type (Left_BT);
            Unsign     : constant Boolean   := Is_Unsigned_Type (Left_BT);
            Subp       : Opf                := null;
            Result     : GL_Value;
            Ovfl_Name  : String (1 .. 4);

         begin
            case Nkind (Node) is
               when N_Op_Add =>
                  if Do_Overflow_Check (Node) then
                     Ovfl_Name := (if Unsign then "uadd" else "sadd");
                  else
                     Subp := (if FP then F_Add'Access else NSW_Add'Access);
                  end if;

               when N_Op_Subtract =>
                  if Do_Overflow_Check (Node) then
                     Ovfl_Name := (if Unsign then "usub" else "ssub");
                  else
                     Subp := (if FP then F_Sub'Access else NSW_Sub'Access);
                  end if;

               when N_Op_Multiply =>
                  if Do_Overflow_Check (Node) then
                     Ovfl_Name := (if Unsign then "umul" else "smul");
                  else
                     Subp := (if FP then F_Mul'Access else NSW_Mul'Access);
                  end if;

               when N_Op_Divide =>
                  Subp :=
                    (if FP then F_Div'Access
                     elsif Unsign then U_Div'Access else S_Div'Access);

               when N_Op_Rem =>
                  Subp := (if Unsign then U_Rem'Access else S_Rem'Access);

               when N_Op_And =>
                  Subp := Build_And'Access;

               when N_Op_Or =>
                  Subp := Build_Or'Access;

               when N_Op_Xor =>
                  Subp := Build_Xor'Access;

               when N_Op_Mod =>
                  Subp := (if Unsign then U_Rem'Access else S_Rem'Access);

               when others =>
                  null;

            end case;

            --  We either do a normal operation if Subp is not null or an
            --  overflow test.

            if Subp /= null then
               Result := Subp (LVal, RVal);
            else
               pragma Assert (Do_Overflow_Check (Node));

               declare
                  Func      : constant GL_Value  :=
                    Build_Intrinsic
                    (Overflow,
                     "llvm." & Ovfl_Name & ".with.overflow.i", Left_BT);
                  Fn_Ret    : constant GL_Value  :=
                    Call (Func, Left_BT, (1 => LVal, 2 => RVal));
                  Overflow  : constant GL_Value  :=
                    Extract_Value (Standard_Boolean, Fn_Ret, 1, "overflow");
                  Label_Ent : constant Entity_Id :=
                    Get_Exception_Goto_Entry (N_Raise_Constraint_Error);
                  BB_Next   : Basic_Block_T;

               begin
                  if Present (Label_Ent) then
                     BB_Next := Create_Basic_Block;
                     Build_Cond_Br
                       (Overflow, Get_Label_BB (Label_Ent), BB_Next);
                     Position_Builder_At_End (BB_Next);
                  else
                     Emit_LCH_Call_If (Overflow, Node);
                  end if;

                  Result := Extract_Value (Left_BT, Fn_Ret, 0);
               end;
            end if;

            --  If this is a signed mod operation, we have to adjust the
            --  result, since what we did is a rem operation.  If the result
            --  is zero or the result and the RHS have the same sign, the
            --  result is correct.  Otherwise, we have to add the RHS to
            --  the result.  Two values have the same sign iff their xor
            --  is non-negative, which is the best code for the general case,
            --  but having a variable as the second operand of mod is quite
            --  rare, so it's best to do slightly less efficient code for
            --  then general case that will get constant-folded in the
            --  constant case.

            if not Unsign and Nkind (Node) = N_Op_Mod then
               declare
                  Add_Back      : constant GL_Value :=
                    NSW_Add (Result, RVal, "addback");
                  RHS_Neg       : constant GL_Value :=
                    I_Cmp (Int_SLT, RVal, Const_Null (RVal),
                           "RHS-neg");
                  Result_Nonpos : constant GL_Value :=
                    I_Cmp (Int_SLE, Result, Const_Null (Result),
                           "result-nonpos");
                  Result_Nonneg : constant GL_Value :=
                    I_Cmp (Int_SGE, Result, Const_Null (Result),
                           "result-nonneg");
                  Signs_Same    : constant GL_Value :=
                    Build_Select (RHS_Neg, Result_Nonpos, Result_Nonneg,
                                  "signs-same");
               begin
                  Result := Build_Select (Signs_Same, Result, Add_Back);
               end;

            --  If this is a division operation with Round_Result set, we
            --  have to do that rounding.  There are two different cases,
            --  one for signed and one for unsigned.

            elsif Nkind (Node) = N_Op_Divide
              and then Rounded_Result (Node) and then Unsign
            then
               declare

                  --  We compute the remainder.  If the remainder is greater
                  --  then half of the RHS (e.g., > (RHS + 1) / 2), we add
                  --  one to the result.

                  Remainder       : constant GL_Value :=
                    U_Rem (LVal, RVal);
                  Half_RHS        : constant GL_Value :=
                    L_Shr (NSW_Sub (RVal, Const_Int (RVal, 1)),
                           Const_Int (RVal, 1));
                  Result_Plus_One : constant GL_Value :=
                    NSW_Add (Result, Const_Int (RVal, 1));
                  Need_Adjust     : constant GL_Value :=
                    I_Cmp (Int_UGT, Remainder, Half_RHS);
               begin
                  Result := Build_Select
                    (Need_Adjust, Result_Plus_One, Result);
               end;

            elsif Nkind (Node) = N_Op_Divide
              and then Rounded_Result (Node) and then not Unsign
            then
               declare

                  --  We compute the remainder.  Then it gets more
                  --  complicated.  As in the mod case, we optimize for the
                  --  case when RHS is a constant.  If twice the absolute
                  --  value of the remainder is greater than RHS, we have
                  --  to either add or subtract one from the result,
                  --  depending on whether RHS is positive or negative.

                  Remainder        : constant GL_Value := S_Rem (LVal, RVal);
                  Rem_Negative     : constant GL_Value :=
                    I_Cmp (Int_SLT, Remainder, Const_Null (Remainder));
                  Abs_Rem          : constant GL_Value :=
                    Build_Select (Rem_Negative, NSW_Neg (Remainder),
                                  Remainder);
                  RHS_Negative     : constant GL_Value :=
                    I_Cmp (Int_SLT, RVal, Const_Null (RVal));
                  Abs_RHS : constant GL_Value :=
                    Build_Select (RHS_Negative, NSW_Neg (RVal), RVal);
                  Need_Adjust      : constant GL_Value :=
                    I_Cmp (Int_UGE, Shl (Abs_Rem, Const_Int (RVal, 1)),
                           Abs_RHS);
                  Result_Plus_One  : constant GL_Value :=
                    NSW_Add (Result, Const_Int (RVal, 1));
                  Result_Minus_One : constant GL_Value :=
                    NSW_Sub (Result, Const_Int (RVal, 1));
                  Which_Adjust     : constant GL_Value :=
                    Build_Select (RHS_Negative, Result_Minus_One,
                                  Result_Plus_One);

               begin
                  Result := Build_Select (Need_Adjust, Which_Adjust, Result);
               end;
            end if;

            return Result;

         end;

      else
         case Nkind (Node) is

            when N_Expression_With_Actions =>
               Emit_List (Actions (Node));
               return Emit_Expression (Expression (Node));

            when N_Character_Literal | N_Numeric_Or_String_Literal =>
               return Emit_Literal (Node);

            when N_And_Then | N_Or_Else =>
               return Build_Short_Circuit_Op
                 (Left_Opnd (Node), Right_Opnd (Node), Nkind (Node));

            when N_Op_Not =>
               return Build_Not (Emit_Expression (Right_Opnd (Node)));

            when N_Op_Abs =>

               --  Emit: X >= 0 ? X : -X;

               declare
                  Expr      : constant GL_Value :=
                    Emit_Expression (Right_Opnd (Node));
                  Zero      : constant GL_Value := Const_Null (Expr);
                  Compare   : constant GL_Value :=
                    Emit_Elementary_Comparison (N_Op_Ge, Expr, Zero);
                  Neg_Expr  : constant GL_Value :=
                    (if Is_Floating_Point_Type (Expr)
                     then F_Neg (Expr) else NSW_Neg (Expr));

               begin
                  if Is_Unsigned_Type (Expr) then
                     return Expr;
                  else
                     return Build_Select (Compare, Expr, Neg_Expr, "abs");
                  end if;
               end;

            when N_Op_Plus =>
               return Emit_Expression (Right_Opnd (Node));

            when N_Op_Minus =>
               declare
                  Expr : constant GL_Value  :=
                    Emit_Expression (Right_Opnd (Node));
                  Typ  : constant Entity_Id := Full_Etype (Expr);

               begin
                  if Is_Floating_Point_Type (Expr) then
                     return F_Neg (Expr);
                  elsif Do_Overflow_Check (Node)
                    and then not Is_Unsigned_Type (Expr)
                  then
                     declare
                        Func      : constant GL_Value :=
                          Build_Intrinsic
                          (Overflow, "llvm.ssub.with.overflow.i", Typ);
                        Fn_Ret    : constant GL_Value :=
                          Call (Func, Typ, (1 => Const_Null (Typ), 2 => Expr));
                        Overflow  : constant GL_Value :=
                          Extract_Value
                          (Standard_Boolean, Fn_Ret, 1, "overflow");
                        Label_Ent : constant Entity_Id :=
                          Get_Exception_Goto_Entry (N_Raise_Constraint_Error);
                        BB_Next   : Basic_Block_T;

                     begin
                        if Present (Label_Ent) then
                           BB_Next := Create_Basic_Block;
                           Build_Cond_Br
                             (Overflow, Get_Label_BB (Label_Ent), BB_Next);
                           Position_Builder_At_End (BB_Next);
                        else
                           Emit_LCH_Call_If (Overflow, Node);
                        end if;

                        return Extract_Value (Typ, Fn_Ret, 0);
                     end;
                  else
                     return NSW_Neg (Expr);
                  end if;
               end;

            when N_Unchecked_Type_Conversion =>
               return Build_Unchecked_Conversion (Expression (Node), TE);

            when N_Type_Conversion | N_Qualified_Expression =>
               return Build_Type_Conversion (Expression (Node), TE);

            when N_Identifier | N_Expanded_Name | N_Operator_Symbol =>

               --  ?? What if Node is a formal parameter passed by reference?
               --  pragma Assert (not Is_Formal (Entity (Node)));

               --  N_Defining_Identifier nodes for enumeration literals are not
               --  stored in the environment. Handle them here.

               declare
                  Def_Ident : Entity_Id := Entity (Node);

               begin
                  --  If this is a deferred constant, look at private version

                  if Ekind (Def_Ident) = E_Constant
                    and then Present (Full_View (Def_Ident))
                    and then No (Address_Clause (Def_Ident))
                  then
                     Def_Ident := Full_View (Def_Ident);
                  end if;

                  if Ekind (Def_Ident) = E_Enumeration_Literal then
                     return Const_Int (TE, Enumeration_Rep (Def_Ident));

                  --  If this entity has a known constant value, use it

                  elsif Ekind (Def_Ident) = E_Constant
                    and then Present (Constant_Value (Def_Ident))
                    and then Compile_Time_Known_Value
                    (Constant_Value (Def_Ident))
                  then
                     return Emit_Expression (Constant_Value (Def_Ident));

                  --  See if this is an entity that's present in our
                  --  activation record. ?? This only handles one level.

                  elsif Ekind_In (Def_Ident, E_Constant,
                                  E_Discriminant,
                                  E_In_Parameter,
                                  E_In_Out_Parameter,
                                  E_Loop_Parameter,
                                  E_Out_Parameter,
                                  E_Variable)
                    and then Present (Activation_Record_Component (Def_Ident))
                    and then Present (Activation_Rec_Param)
                    and then Get_Value (Scope (Def_Ident)) /= Current_Func
                  then
                     declare
                        Component         : constant Entity_Id :=
                          Activation_Record_Component (Def_Ident);
                        Activation_Record : constant GL_Value :=
                          Activation_Rec_Param;
                        Pointer           : constant GL_Value :=
                          Record_Field_Offset (Activation_Record, Component);
                        Value_Address     : constant GL_Value :=
                          Load (Pointer);
                        Value_Ptr         : constant GL_Value :=
                          Int_To_Ref (Value_Address, Full_Etype (Def_Ident));
                     begin
                        return Load (Value_Ptr);
                     end;

                     --  Handle entities in Standard and ASCII on the fly

                  elsif Sloc (Def_Ident) <= Standard_Location then
                     declare
                        N    : constant Node_Id := Get_Full_View (Def_Ident);
                        Decl : constant Node_Id := Declaration_Node (N);
                        Expr : Node_Id := Empty;

                     begin
                        if Nkind (Decl) /= N_Object_Renaming_Declaration then
                           Expr := Expression (Decl);
                        end if;

                        if Present (Expr)
                          and then Nkind_In (Expr, N_Character_Literal,
                                             N_Expanded_Name,
                                             N_Integer_Literal,
                                             N_Real_Literal)
                        then
                           return Emit_Expression (Expr);

                        elsif Present (Expr)
                          and then Nkind (Expr) = N_Identifier
                          and then (Ekind (Entity (Expr))
                                      = E_Enumeration_Literal)
                        then
                           return
                             Const_Int (TE, Enumeration_Rep (Entity (Expr)));
                        else
                           return Emit_Expression (N);
                        end if;
                     end;

                  elsif Nkind (Node) in N_Subexpr
                    and then Is_Constant_Folded (Entity (Node))
                  then
                     --  Replace constant references by the direct values,
                     --  to avoid a level of indirection for e.g. private
                     --  values and to allow generation of static values
                     --  and static aggregates.

                     declare
                        N    : constant Node_Id :=
                          Get_Full_View (Entity (Node));
                        Decl : constant Node_Id := Declaration_Node (N);
                        Expr : Node_Id := Empty;

                     begin
                        if Nkind (Decl) /= N_Object_Renaming_Declaration then
                           Expr := Expression (Decl);
                        end if;

                        if Present (Expr) then
                           if Nkind_In (Expr, N_Character_Literal,
                                        N_Expanded_Name,
                                        N_Integer_Literal,
                                        N_Real_Literal)
                             or else (Nkind (Expr) = N_Identifier
                                        and then Ekind (Entity (Expr)) =
                                        E_Enumeration_Literal)
                           then
                              return Emit_Expression (Expr);
                           end if;
                        end if;
                     end;
                  end if;

                  return Need_Value (Get_Value (Def_Ident),
                                     Full_Etype (Def_Ident));
               end;

            when N_Function_Call =>
               return Emit_Call (Node);

            when N_Explicit_Dereference =>
               return Need_Value
                 (Make_Reference (Emit_Expression (Prefix (Node))), TE);

            when N_Allocator =>
               if Present (Storage_Pool (Node)) then
                  Error_Msg_N ("unsupported form of N_Allocator", Node);
                  return Get_Undef (TE);
               end if;

               declare
                  Expr             : constant Node_Id := Expression (Node);
                  Typ              : Entity_Id;
                  Value            : GL_Value;
                  Result           : GL_Value;

               begin
                  --  There are two cases: the Expression operand can either be
                  --  an N_Identifier or Expanded_Name, which must represent a
                  --  type, or a N_Qualified_Expression, which contains both
                  --  the object type and an initial value for the object.

                  if Is_Entity_Name (Expr) then
                     Typ   := Get_Fullest_View (Entity (Expr));
                     Value := No_GL_Value;
                  else
                     pragma Assert (Nkind (Expr) = N_Qualified_Expression);
                     Typ   := Full_Etype (Expression (Expr));
                     Value := Emit_Expression (Expression (Expr));
                  end if;

                  Result := Call (Get_Default_Alloc_Fn, Standard_A_Char,
                                  (1 => Get_Type_Size
                                     (Typ, Value, For_Type => No (Value))));

                  --  Convert to a pointer to the type that the thing is
                  --  suppose to point to.

                  Result := Ptr_To_Ref (Result, Typ);

                  --  Now copy the data, if there is any, into the value

                  if Nkind (Expr) = N_Qualified_Expression then
                     Emit_Assignment (Result, Empty, Value, True, True);
                  end if;

                  return
                    Convert_To_Access_To (Result, Full_Designated_Type (TE));
               end;

            when N_Reference =>
               return Emit_LValue (Prefix (Node));

            when N_Attribute_Reference =>
               return Emit_Attribute_Reference (Node, LValue => False);

            when N_Selected_Component | N_Indexed_Component  | N_Slice =>
               return Need_Value (Emit_LValue (Node), TE);

            when N_Aggregate | N_Extension_Aggregate =>

               if Null_Record_Present (Node) and then not Is_Dynamic_Size (TE)
               then
                  return Const_Null (Full_Etype (Node));

               elsif Ekind (TE) in Record_Kind then
                  return Emit_Record_Aggregate (Node, Get_Undef (TE));

               else
                  return Emit_Array_Aggregate
                    (Node, Number_Dimensions (TE), (1 .. 0 => <>),
                     Get_Undef (TE));
               end if;

            when N_If_Expression =>
               return Emit_If_Expression (Node);

            when N_Null =>
               return Const_Null (TE);

            when N_Defining_Identifier | N_Defining_Operator_Symbol =>
               return Get_Value (Node);

            when N_In =>
               declare
                  Rng   : Node_Id := Right_Opnd (Node);
                  Left  : constant GL_Value :=
                    Emit_Expression (Left_Opnd (Node));

               begin
                  pragma Assert (No (Alternatives (Node)));
                  pragma Assert (Present (Rng));
                  --  The front end guarantees the above

                  if Nkind (Rng) = N_Identifier then
                     Rng := Scalar_Range (Full_Etype (Rng));
                  end if;

                  return Build_And (Emit_Elementary_Comparison
                                      (N_Op_Ge, Left,
                                       Emit_Expression (Low_Bound (Rng))),
                                    Emit_Elementary_Comparison
                                      (N_Op_Le, Left,
                                       Emit_Expression (High_Bound (Rng))));
               end;

            when N_Raise_Expression =>
               Emit_LCH_Call (Node);
               return Get_Undef (TE);

            when N_Raise_xxx_Error =>
               pragma Assert (No (Condition (Node)));
               Emit_LCH_Call (Node);
               return Get_Undef (TE);

            when others =>
               Error_Msg_N
                 ("unsupported node kind: `" &
                    Node_Kind'Image (Nkind (Node)) & "`", Node);
               return Get_Undef (TE);
         end case;
      end if;
   end Emit_Expression;

   ---------------
   -- Emit_List --
   ---------------

   procedure Emit_List (List : List_Id) is
      N : Node_Id;

   begin
      if Present (List) then
         N := First (List);
         while Present (N) loop
            Emit (N);
            Next (N);
         end loop;
      end if;
   end Emit_List;

   -----------------------
   -- Is_Zero_Aggregate --
   -----------------------

   function Is_Zero_Aggregate (Src_Node : Node_Id) return Boolean is
      Inner    : Node_Id;
      Val      : Uint;

   begin
      Inner := Expression (First (Component_Associations (Src_Node)));
      while Nkind_In (Inner, N_Aggregate, N_Extension_Aggregate)
        and then Is_Others_Aggregate (Inner)
      loop
         Inner := Expression (First (Component_Associations (Inner)));
      end loop;

      Val := Get_Uint_Value (Inner);
      return Val = Uint_0;
   end Is_Zero_Aggregate;

   ---------------------
   -- Emit_Assignment --
   ---------------------

   procedure Emit_Assignment
     (LValue                    : GL_Value;
      Orig_E                    : Node_Id;
      E_Value                   : GL_Value;
      Forwards_OK, Backwards_OK : Boolean)
   is
      Dest_Type : constant Entity_Id := Full_Designated_Type (LValue);
      E         : Node_Id            := Orig_E;
      Dest      : GL_Value           := LValue;
      Src       : GL_Value;

   begin

      --  Remove any conversion from E if they are record or array
      --  conversions that increase the complexity of the size of the
      --  type because we'll be doing any needed conversions below.

      while Nkind_In (E, N_Type_Conversion, N_Unchecked_Type_Conversion,
                      N_Qualified_Expression)
        and then Is_Composite_Type (Full_Etype (E))
        and then (Get_Type_Size_Complexity (Full_Etype (E))
                    > Get_Type_Size_Complexity (Full_Etype (Expression (E))))
      loop
         E := Expression (E);
      end loop;

      --  See if we have the special case where we're assigning all zeros.
      --  ?? This should really be in Emit_Array_Aggregate, which should take
      --  an LHS.

      if Is_Array_Type (Full_Designated_Type (LValue)) and then Present (E)
        and then Nkind_In (E, N_Aggregate, N_Extension_Aggregate)
        and then Is_Others_Aggregate (E) and then Is_Zero_Aggregate (E)
      then
         declare
            Align : constant unsigned := Get_Type_Alignment (Dest_Type);

         begin
            Call (Build_Intrinsic
                    (Memset, "llvm.memset.p0i8.i", Size_Type),
                  (1 => Bit_Cast (Dest, Standard_A_Char),
                   2 => Const_Null (Standard_Short_Short_Integer),
                   3 => Get_Type_Size (Dest_Type, No_GL_Value),
                   4 => Const_Int_32 (unsigned_long_long (Align)),
                   5 => Const_False));  --  Is_Volatile
         end;

      --  We now have three case: where we're copying an object of an
      --  elementary type, where we're copying an object that's not
      --  elementary, but can be copied with a Store instruction, or where
      --  we're copying an object of variable size.

      elsif Is_Elementary_Type (Dest_Type) then

         --  The easy case: convert the source to the destination type and
         --  store it.

         Src := (if No (E_Value) then Emit_Expression (E) else E_Value);
         Store (Convert_To_Elementary_Type (Src, Dest_Type), Dest);

      elsif (Present (E) and then not Is_Dynamic_Size (Full_Etype (E)))
         or else (Present (E_Value) and then not Is_Reference (E_Value))
      then
         Src := (if No (E_Value) then Emit_Expression (E) else E_Value);

         --  Here, we have the situation where the source is of an LLVM
         --  value, but the destiation may or may not be a variable-sized
         --  type.  In that case, since we know the size and know the object
         --  to store, we can convert Dest to the type of the pointer to
         --  Src, which we know is fixed-size, and do the store.  If Dest
         --  is pointer to an array type, we need to get the actual array
         --  data.

         if Pointer_Type (Type_Of (Src),  0) /= Type_Of (Dest) then
            if Is_Array_Type (Full_Designated_Type (Dest)) then
               Dest := Array_Data (Dest);
            end if;

            Dest := Ptr_To_Ref (Dest, Full_Etype (Src));
         end if;

         Store (Src, Dest);

      else
         Src := (if No (E_Value) then Emit_LValue (E, Clear => False)
                 else E_Value);

         --  Otherwise, we have to do a variable-sized copy

         declare
            Size      : constant GL_Value := Compute_Size
              (Dest_Type, Full_Designated_Type (Src), Dest, Src);
            Align     : constant unsigned := Compute_Alignment
              (Dest_Type, Full_Designated_Type (Src));
            Func_Name : constant String   :=
              (if Forwards_OK and then Backwards_OK
               then "memcpy" else "memmove");

         begin

            --  If this is an array type, we have to point the memcpy/memmove
            --  to the underlying data.  But be sure we've done this after
            --  we've used the fat pointer to compute the size above.

            if Is_Array_Type (Full_Designated_Type (Src)) then
               Dest := Array_Data (Dest);
               Src  := Array_Data (Src);
            end if;

            Call (Build_Intrinsic
                    (Memcpy, "llvm." & Func_Name & ".p0i8.p0i8.i", Size_Type),
                  (1 => Bit_Cast (Dest, Standard_A_Char),
                   2 => Bit_Cast (Src, Standard_A_Char),
                   3 => Size,
                   4 => Const_Int_32 (unsigned_long_long (Align)),
                   5 => Const_False)); -- Is_Volatile
         end;
      end if;
   end Emit_Assignment;

   ------------------------------
   -- Emit_Attribute_Reference --
   ------------------------------

   function Emit_Attribute_Reference
     (N : Node_Id; LValue : Boolean) return GL_Value
   is
      Attr : constant Attribute_Id := Get_Attribute_Id (Attribute_Name (N));
      TE   : constant Entity_Id := Full_Etype (N);
      V    : GL_Value;

   begin
      case Attr is
         when Attribute_Access
            | Attribute_Unchecked_Access
            | Attribute_Unrestricted_Access =>
            --  We store values as pointers, so, getting an access to an
            --  expression is the same thing as getting an LValue, and has
            --  the same constraints.  But we do have to be sure that it's
            --  of the right type.

            return Convert_To_Access_To (Emit_LValue (Prefix (N)),
                                         Full_Designated_Type (TE));

         when Attribute_Address =>
            V := Emit_LValue (Prefix (N));
            return (if LValue then V else Ptr_To_Int (V, TE, "attr-address"));

         when Attribute_Deref =>
            declare
               Expr : constant Node_Id := First (Expressions (N));
               pragma Assert (Is_Descendant_Of_Address (Full_Etype (Expr)));

            begin
               V := Int_To_Ref (Emit_Expression (Expr), TE, "attr-deref");
               return (if LValue then V else Need_Value (V, TE));
            end;

         when Attribute_First
            | Attribute_Last
            | Attribute_Length
            | Attribute_Range_Length =>

            declare
               Prefix_Type : constant Entity_Id := Full_Etype (Prefix (N));
               Dim         : constant Nat       :=
                 (if Present (Expressions (N))
                  then UI_To_Int (Intval (First (Expressions (N)))) - 1
                  else 0);
               Array_Descr : GL_Value;
               Result      : GL_Value;
               Low, High   : GL_Value;
            begin
               if Is_Scalar_Type (Prefix_Type) then
                  Low  := Emit_Expression (Type_Low_Bound (Prefix_Type));
                  High := Emit_Expression (Type_High_Bound (Prefix_Type));

                  if Attr = Attribute_First then
                     Result := Low;
                  elsif Attr = Attribute_Last then
                     Result := High;
                  elsif Attr = Attribute_Range_Length then
                     Result := Bounds_To_Length (Low, High, TE);
                  else
                     Error_Msg_N ("unsupported attribute: `" &
                                    Attribute_Id'Image (Attr) & "`", N);
                     Result := Get_Undef (TE);
                  end if;

               elsif Is_Array_Type (Prefix_Type) then

                  --  If what we're taking the prefix of is a type, we can't
                  --  evaluate it as an expression.

                  if Is_Entity_Name (Prefix (N))
                    and then Is_Type (Entity (Prefix (N)))
                  then
                     Array_Descr := No_GL_Value;
                  else
                     Array_Descr := Emit_LValue (Prefix (N));
                  end if;

                  if Attr = Attribute_Length then
                     Result :=
                       Get_Array_Length (Prefix_Type, Dim, Array_Descr);
                  else
                     Result :=
                       Get_Array_Bound
                       (Prefix_Type, Dim, Attr = Attribute_First, Array_Descr);
                  end if;
               else
                  Error_Msg_N ("unsupported attribute: `" &
                                 Attribute_Id'Image (Attr) & "`", N);
                  Result := Get_Undef (TE);
               end if;

               return Convert_To_Elementary_Type (Result, TE);
            end;

         when Attribute_Max
            | Attribute_Min =>
            pragma Assert (List_Length (Expressions (N)) = 2);
            return Emit_Min_Max (Expressions (N), Attr = Attribute_Max);

         when Attribute_Pos
            | Attribute_Val =>
            return Build_Type_Conversion (First (Expressions (N)), TE);

         when Attribute_Succ
            | Attribute_Pred =>
            declare
               Exprs : constant List_Id  := Expressions (N);
               Base  : constant GL_Value := Emit_Expression (First (Exprs));
               One   : constant GL_Value := Const_Int (Base, Uint_1);

            begin
               pragma Assert (List_Length (Exprs) = 1);
               return
                 (if Attr = Attribute_Succ
                  then NSW_Add (Base, One, "attr-succ")
                  else NSW_Sub (Base, One, "attr-pred"));
            end;

         when Attribute_Machine =>

            --  ??? For now return the prefix itself. Would need to force a
            --  store in some cases.

            return Emit_Expression (First (Expressions (N)));

         when Attribute_Alignment =>
            declare
               Pre   : constant Node_Id  := Full_Etype (Prefix (N));
               Align : constant unsigned := Get_Type_Alignment (Pre);

            begin
               return Const_Int (TE, unsigned_long_long (Align),
                                 Sign_Extend => False);
            end;

         when Attribute_Size
            | Attribute_Object_Size
            | Attribute_Value_Size =>

            --  ?? These aren't quite the same thing, but they're close
            --  enough for quite a while.

            declare
               Prefix_Type : constant Entity_Id := Full_Etype (Prefix (N));
               For_Type    : constant Boolean   :=
                 (Is_Entity_Name (Prefix (N))
                    and then Is_Type (Entity (Prefix (N))));

            begin
               V := (if For_Type then No_GL_Value
                                 else Emit_LValue (Prefix (N)));
               return Convert_To_Elementary_Type
                 (NSW_Mul (Get_Type_Size (Prefix_Type, V, For_Type),
                           Size_Const_Int (8)),
                  TE);
            end;

         when others =>
            Error_Msg_N ("unsupported attribute: `" &
                           Attribute_Id'Image (Attr) & "`", N);
            return Get_Undef (TE);
      end case;
   end Emit_Attribute_Reference;

   ------------------
   -- Emit_Literal --
   ------------------

   function Emit_Literal (N : Node_Id) return GL_Value is
      TE : constant Entity_Id := Full_Etype (N);
   begin
      case Nkind (N) is
         when N_Character_Literal =>

            --  If a Entity is present, it means that this was one of the
            --  literals in a user-defined character type.

            return Const_Int (TE, (if Present (Entity (N))
                                   then Enumeration_Rep (Entity (N))
                                   else Char_Literal_Value (N)));

         when N_Integer_Literal =>
            return Const_Int (TE, Intval (N));

         when N_Real_Literal =>
            if Is_Fixed_Point_Type (TE) then
               return Const_Int (TE, Corresponding_Integer_Value (N));
            else
               declare
                  Val              : Ureal := Realval (N);
                  FP_Num, FP_Denom : double;

               begin
                  if UR_Is_Zero (Val) then
                     return Const_Real (TE, 0.0);
                  end if;

                  --  First convert the value to a machine number if it isn't
                  --  already. That will force the base to 2 for non-zero
                  --  values and simplify the rest of the logic.

                  if not Is_Machine_Number (N) then
                     Val := Machine
                       (Implementation_Base_Type (TE), Val, Round_Even, N);
                  end if;

                  pragma Assert (Rbase (Val) = 2);

                  --  ??? This code is not necessarily the most efficient,
                  --  may not give full precision in all cases, and may not
                  --  handle denormalized constants, but should work in enough
                  --  cases for now.

                  FP_Num :=
                    double (UI_To_Long_Long_Integer (Numerator (Val)));
                  if UR_Is_Negative (Val) then
                     FP_Num := -FP_Num;
                  end if;

                  FP_Denom :=
                    2.0 ** (Integer (-UI_To_Int (Denominator (Val))));
                  return Const_Real (TE, FP_Num * FP_Denom);
               end;
            end if;

         when N_String_Literal =>
            declare
               String       : constant String_Id := Strval (N);
               Array_Type   : constant Type_T := Create_Type (TE);
               Element_Type : constant Type_T := Get_Element_Type (Array_Type);
               Length       : constant Interfaces.C.unsigned :=
                 Get_Array_Length (Array_Type);
               Elements     : array (1 .. Length) of Value_T;

            begin
               for J in Elements'Range loop
                  Elements (J) := Const_Int
                    (Element_Type,
                     unsigned_long_long
                       (Get_String_Char (String, Standard.Types.Int (J))),
                     Sign_Extend => False);
               end loop;

               return G (Const_Array (Element_Type, Elements'Address, Length),
                         TE);
            end;

         when others =>
            Error_Msg_N ("unhandled literal node", N);
            return Get_Undef (TE);

      end case;
   end Emit_Literal;

   ----------------
   -- Emit_Shift --
   ----------------

   function Emit_Shift
     (Operation           : Node_Kind;
      LHS_Node, RHS_Node  : Node_Id) return GL_Value
   is
      To_Left, Rotate, Arithmetic : Boolean := False;

      LHS       : constant GL_Value := Emit_Expression (LHS_Node);
      RHS       : constant GL_Value := Emit_Expression (RHS_Node);
      N         : constant GL_Value := Convert_To_Elementary_Type (RHS, LHS);
      LHS_Size  : constant GL_Value := Get_LLVM_Type_Size_In_Bits (LHS);
      LHS_Bits  : constant GL_Value :=
        Convert_To_Elementary_Type (LHS_Size, LHS);
      Result    : GL_Value          := LHS;
      Saturated : GL_Value;

   begin
      --  Extract properties for the operation we are asked to generate code
      --  for.  We defaulted to a right shift above.

      case Operation is
         when N_Op_Shift_Left =>
            To_Left := True;
         when N_Op_Shift_Right_Arithmetic =>
            Arithmetic := True;
         when N_Op_Rotate_Left =>
            To_Left := True;
            Rotate := True;
         when N_Op_Rotate_Right =>
            Rotate := True;
         when others =>
            null;
      end case;

      if Rotate then

         --  LLVM instructions will return an undefined value for
         --  rotations with too many bits, so we must handle "multiple
         --  turns".  However, the front-end has already computed the modulus.

         declare
            --  There is no "rotate" instruction in LLVM, so we have to stick
            --  to shift instructions, just like in C. If we consider that we
            --  are rotating to the left:
            --
            --     Result := (Operand << Bits) | (Operand >> (Size - Bits));
            --               -----------------   --------------------------
            --                    Upper                   Lower
            --
            --  If we are rotating to the right, we switch the direction of the
            --  two shifts.

            Lower_Shift : constant GL_Value :=
              NSW_Sub (LHS_Bits, N, "lower-shift");
            Upper       : constant GL_Value :=
              (if To_Left
               then Shl   (LHS, N, "rotate-upper")
               else L_Shr (LHS, N, "rotate-upper"));
            Lower       : constant GL_Value :=
              (if To_Left
               then L_Shr (LHS, Lower_Shift, "rotate-lower")
               else Shl   (LHS, Lower_Shift, "rotate-lower"));

         begin
            return Build_Or (Upper, Lower, "rotate-result");
         end;

      else
         --  If the number of bits shifted is bigger or equal than the number
         --  of bits in LHS, the underlying LLVM instruction returns an
         --  undefined value, so build what we want ourselves (we call this
         --  a "saturated value").

         Saturated :=
           (if Arithmetic

            --  If we are performing an arithmetic shift, the saturated value
            --  is 0 if LHS is positive, -1 otherwise (in this context, LHS is
            --  always interpreted as a signed integer).

            then Build_Select
              (C_If   => I_Cmp
                 (Int_SLT, LHS, Const_Null (LHS), "is-lhs-negative"),
               C_Then => Const_Ones (LHS),
               C_Else => Const_Null (LHS),
               Name   => "saturated")

            else Const_Null (LHS));

         --  Now, compute the value using the underlying LLVM instruction

         Result :=
           (if To_Left
            then Shl (LHS, N)
            else
              (if Arithmetic
               then A_Shr (LHS, N) else L_Shr (LHS, N)));

         --  Now, we must decide at runtime if it is safe to rely on the
         --  underlying LLVM instruction. If so, use it, otherwise return
         --  the saturated value.

         return Build_Select
           (C_If   => I_Cmp (Int_UGE, N, LHS_Bits, "is-saturated"),
            C_Then => Saturated,
            C_Else => Result,
            Name   => "shift-rotate-result");
      end if;
   end Emit_Shift;

end GNATLLVM.Compile;
