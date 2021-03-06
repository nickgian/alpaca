open Format
open Types
open AstTypes
open Identifier
open Error
open SymbTypes
open Symbol
open Pretty_print


module Label : 
sig
  type t = int
  val label : t ref 
  (* Create and return a new label *)
  val newLabel : unit -> t
  (* Return next label *)
  val nextLabel : unit -> t
  val label_of_string : t -> string
end =
struct
  type t = int
  let label = ref 0
  let newLabel () = incr label; !label 
  let nextLabel () = !label + 1
  let label_of_string x = string_of_int x
end

module type LABEL_LIST =  
sig
  type labelList = Label.t list
  (* create an empty labelList *)
  val newLabelList : unit -> labelList
  (* create a labelList with label n *) 
  val makeLabelList : Label.t -> labelList
  (* add a new label to labelList *)
  val addLabel : Label.t -> labelList -> labelList
  (* return true if no labels are stored *)
  val is_empty : labelList -> bool
  (* raised on remove/peek of empty labelList *) 
  exception EmptyLabelList
  (* retrieve first element and return rest of labelList *)
  val removeLabel : labelList -> Label.t * labelList
  (* peek at first element *)
  val peekLabel : labelList -> Label.t
  (* merge two labelLists *)
  val mergeLabels : labelList -> labelList -> labelList
end

module Labels : LABEL_LIST =
struct
  type labelList = Label.t list
  exception EmptyLabelList
  let newLabelList () : labelList = []
  let makeLabelList (n : Label.t) = [n]
  let addLabel (n : Label.t) (l : labelList) = n :: l
  let is_empty (l : labelList) = l = []
  let removeLabel (l : labelList) =
    match l with 
      | [] -> raise EmptyLabelList
      | n :: t -> (n, t)
  let peekLabel (l : labelList) = 
    match l with
      | [] -> raise EmptyLabelList
      | n :: _ -> n
  let mergeLabels (l1 : labelList) (l2 : labelList) = l1 @ l2
end

type quad_operators =
  | Q_Unit | Q_Endu
  | Q_Plus | Q_Minus | Q_Mult | Q_Div | Q_Mod
  | Q_Fplus | Q_Fminus | Q_Fmult | Q_Fdiv 
  | Q_L | Q_Le | Q_G | Q_Ge | Q_Seq | Q_Nseq
  | Q_Eq | Q_Neq (* Physical equality *)
  | Q_Assign | Q_Ifb | Q_Array
  | Q_Jump | Q_Jumpl | Q_Label
  | Q_Call | Q_Par | Q_Ret | Q_Dim
  | Q_Match | Q_Constr | Q_Fail

type quad_operands = 
  | O_Int of int
  | O_Float of float
  | O_Char of string
  | O_Bool of bool
  | O_Str of string 
  | O_Backpatch
  | O_Label of int
  | O_Res (* $$ *)
  | O_Ret (* RET *)
  | O_ByVal
  | O_Entry of entry 
  | O_Empty
  | O_Ref of quad_operands
  | O_Deref of quad_operands
  | O_Size of int
  | O_Dims of int
  | O_Index of quad_operands list

type quad = {
  label : Label.t;
  operator : quad_operators;
  mutable arg1 : quad_operands; (* due to optimizations *)
  mutable arg2 : quad_operands;
  mutable arg3 : quad_operands
}

type expr_info = {
  place : quad_operands;
  next_expr  : Labels.labelList
}

type cond_info = {
  true_lst  : Labels.labelList;
  false_lst : Labels.labelList
}

type stmt_info = { 
  next_stmt : Labels.labelList
}

(* Quads infrastructure *)

let tailRecOpt = ref false
let labelsTbl = Hashtbl.create 101  

(* Modularity *)
let memLabelTbl label = Hashtbl.mem labelsTbl label 
let addLabelTbl label = Hashtbl.replace labelsTbl label 0

(* Create a new temp and register it with the symbol table *)
let newTemp =
  let k = ref 1 in
    fun typ f opt -> 
      let tempsize = sizeOfType typ in
      let size = Symbol.getVarRef f in
        size := !size + tempsize; 
        let header = {  
          entry_id = id_make ("$" ^ string_of_int !k);
          entry_scope = 
            {
              sco_parent = None;
              sco_nesting = 0;
              sco_entries = [];
              sco_negofs  = 0;
              sco_hidden = false;
            };
          entry_info = 
            ENTRY_temporary {
              temporary_type = typ;
              temporary_offset = - !size;
              temporary_index = !k;
              temporary_opt = opt
            }
        }
        in
          Symbol.addTemp header f;
          incr k;
          O_Entry header

let removeTemp arg f = 
  match arg with
      O_Entry e when Symbol.isTemporary e ->
      Symbol.removeTemp e f
    | _ -> internal "Not a temporary"

(* Return quad operator from Llama binary operator *)
let getQuadBop bop = match bop with 
  | Plus -> Q_Plus 
  | Fplus -> Q_Fplus
  | Minus -> Q_Minus
  | Fminus -> Q_Fminus
  | Times -> Q_Mult
  | Ftimes -> Q_Fmult
  | Div  -> Q_Div
  | Fdiv -> Q_Fdiv
  | Mod  -> Q_Mod
  | Seq -> Q_Seq 
  | Nseq -> Q_Nseq
  | L -> Q_L
  | Le -> Q_Le
  | G -> Q_G
  | Ge -> Q_Ge
  | Eq -> Q_Eq
  | Neq -> Q_Neq
  | And | Or | Semicolon | Power -> internal "no operator for and/or/;/pow" 
  | Assign -> Q_Assign

let getQuadUnop unop = match unop with
  | U_Plus -> Q_Plus
  | U_Minus -> Q_Minus
  | U_Fplus -> Q_Fplus
  | U_Fminus -> Q_Fminus
  | U_Not | U_Del -> internal "no operator for not/delete"

let rec getQuadOpType operand =
  match operand with
    | O_Int _ -> T_Int
    | O_Float _ -> T_Float
    | O_Char _ -> T_Char
    | O_Bool _ -> T_Bool
    | O_Str _ -> T_Array (T_Char, D_Dim 1)
    | O_Backpatch -> internal "Backpatch? Here?"
    | O_Label _ -> internal "But a label? Here?"
    | O_Res -> internal "Res? Here?" (* $$ *)
    | O_Ret -> internal "Ret? Here?" (* RET *)
    | O_ByVal -> internal "By Val? Here?"
    | O_Entry e -> getType e
    | O_Empty -> internal "Empty? Here"
    | O_Ref op -> T_Ref (getQuadOpType op)
    | O_Deref op -> 
      (match getQuadOpType op with
        | T_Ref typ -> typ 
        | _ -> internal "Cannot dereference a no reference")
    | O_Size _ -> internal "Size? Here?"
    | O_Dims _ -> internal "Dims? Dims here?"
    | O_Index _ -> internal "Shouldn't be here, something went wrong"

let newQuadList () = []
let isEmptyQuadList quads = quads = []

let genQuad (op, ar1, ar2, ar3) quad_lst =
  let quad = {
    label = Label.newLabel ();
    operator = op;
    arg1 = ar1;
    arg2 = ar2;
    arg3 = ar3
  } 
  in
    (quad :: quad_lst) 

let mergeQuads quads new_quads = quads @ new_quads

let setExprInfo p n = { place = p; next_expr = n }

let setCondInfo t f = { true_lst = t; false_lst = f }

let setStmtInfo n = { next_stmt = n }

(* XXX Backpatch, changes a mutable field so we can maybe avoid returning a new
 * quad list thus avoiding all the quads1,2,3... pollution. Moo XXX*)
let backpatch quads lst patch =
  if (not (isEmptyQuadList lst)) then addLabelTbl patch; 
  List.iter (fun quad_label -> 
      match (try Some (List.find (fun q -> q.label = quad_label) quads) 
             with Not_found -> None) with
        | None -> internal "Quad label not found, can't backpatch\n"
        | Some quad -> quad.arg3 <- O_Label patch) lst;
  quads


let string_of_operator = function 
  | Q_Unit -> "Unit" 
  | Q_Endu -> "Endu"
  | Q_Plus -> "+" 
  | Q_Minus -> "-" 
  | Q_Mult -> "*" 
  | Q_Div -> "/" 
  | Q_Mod -> "Mod"
  | Q_Fplus -> "+."
  | Q_Fminus -> "-." 
  | Q_Fmult -> "*."
  | Q_Fdiv -> "/." 
  | Q_L -> "<"
  | Q_Le -> "<=" 
  | Q_G -> ">" 
  | Q_Ge -> ">=" 
  | Q_Seq -> "=" 
  | Q_Nseq -> "<>"
  | Q_Eq -> "==" 
  | Q_Neq -> "!=" (* Physical equality *)
  | Q_Dim -> "dim"
  | Q_Assign -> ":=" | Q_Ifb -> "ifb" | Q_Array -> "Array"
  | Q_Jump -> "Jump" | Q_Jumpl -> "Jumpl" | Q_Label -> "Label??"
  | Q_Call -> "call" | Q_Par -> "par" | Q_Ret -> "Ret??" 
  | Q_Match -> "match" | Q_Constr -> "constr" | Q_Fail -> "fail"


(** Simpler version of print_indexes, used for cfg*)
let rec string_of_indexes = function
    [] -> ""
  | q :: [] -> string_of_operand q
  | q :: qs -> (string_of_operand q) ^ "," ^ (string_of_indexes qs)

(** Simpler version of print_entry, used for cfg*)
and string_of_entry e =
  let kind = match e.entry_info with
    | ENTRY_function _ -> "fun: " 
    | ENTRY_variable _ -> "var: "
    | ENTRY_parameter _ -> "par: "
    | ENTRY_temporary _ -> "tmp: "
    | ENTRY_constructor _ -> "con: "
    | ENTRY_udt _ -> "udt: "
    | ENTRY_none -> internal "Empty entry occured"
  in
    kind ^ (Identifier.id_name e.entry_id)

(** Returns a string from an operand *)
and string_of_operand = function
  | O_Int i -> Printf.sprintf "%d" i 
  | O_Float f -> Printf.sprintf "%f" f 
  | O_Char str -> Printf.sprintf "\'%s\'" str 
  | O_Bool b -> Printf.sprintf "%b" b 
  | O_Str str -> 
    Printf.sprintf "\"%s\"" str 
  | O_Backpatch -> "*"  
  | O_Label i -> Printf.sprintf "l: %d" i 
  | O_Res -> "$$" 
  | O_Ret -> "RET" 
  | O_ByVal -> "V"
  | O_Entry e -> string_of_entry e
  | O_Empty -> "--"
  | O_Ref op -> Printf.sprintf "{%s}" (string_of_operand op)
  | O_Deref op -> Printf.sprintf "[%s]" (string_of_operand op)
  | O_Size i -> Printf.sprintf "Size %d" i
  | O_Dims i -> Printf.sprintf "Dims %d" i
  | O_Index lst -> Printf.sprintf "Index [%s]" (string_of_indexes lst)


let print_operator chan op = fprintf chan "%s" (string_of_operator op)

let print_entry chan entry =
  match entry.entry_info with
    | ENTRY_function f ->
      let parent_id = match f.function_parent with
        | Some e -> e.entry_id
        | None -> id_make "None"
      in
        fprintf chan "Fun[%a, index %d, params %d, vars %d, nest %d, parent %a]" 
          pretty_id entry.entry_id
          f.function_index f.function_paramsize 
          !(f.function_varsize) f.function_nesting
          pretty_id parent_id
    | ENTRY_variable v -> 
      fprintf chan "Var[%a, type %a, offset %d, nest %d]" 
        pretty_id entry.entry_id pretty_typ v.variable_type 
        v.variable_offset v.variable_nesting
    | ENTRY_parameter p -> 
      fprintf chan "Par[%a, type %a, offset %d, nest %d]" 
        pretty_id entry.entry_id pretty_typ p.parameter_type 
        p.parameter_offset p.parameter_nesting
    | ENTRY_temporary t ->
      fprintf chan "Temp[%a, type %a, offset %d]" 
        pretty_id entry.entry_id pretty_typ t.temporary_type 
        t.temporary_offset
    | ENTRY_constructor c ->
      fprintf chan "Constr[%a, type %a, arity %d, tag %d]" 
        pretty_id entry.entry_id pretty_typ c.constructor_type
        c.constructor_arity c.constructor_tag
    | ENTRY_udt u -> internal "UDT entries should not be visible to user"
    | ENTRY_none -> internal "Error, tried to access empty entry"


let rec print_indexes chan lst =
  let rec pp_indexes ppf lst =
    match lst with
      | [] -> ()
      | x :: [] -> fprintf ppf "%a" print_operand x
      | x :: xs -> fprintf ppf "%a, %a" print_operand x pp_indexes xs
  in
    fprintf chan "%a" pp_indexes lst

and print_operand chan op = match op with
  | O_Int i -> fprintf chan "%d" i 
  | O_Float f -> fprintf chan "%f" f 
  | O_Char str -> fprintf chan "\'%s\'" str 
  | O_Bool b -> fprintf chan "%b" b 
  | O_Str str -> fprintf chan "\"%s\"" (String.escaped str)  
  | O_Backpatch -> fprintf chan "*"  
  | O_Label i -> fprintf chan "l: %d" i 
  | O_Res -> fprintf chan "$$" 
  | O_Ret -> fprintf chan "RET" 
  | O_ByVal -> fprintf chan "V"
  | O_Entry e -> fprintf chan "%a" print_entry e 
  | O_Empty ->  fprintf chan "-"
  | O_Ref op -> fprintf chan "{%a}" print_operand op
  | O_Deref op -> fprintf chan "[%a]" print_operand op
  | O_Size i -> fprintf chan "Size %d" i
  | O_Dims i -> fprintf chan "Dims %d" i
  | O_Index lst -> fprintf chan "Indexes [%a]" print_indexes lst


let entry_of_quadop op = match op with 
  | O_Entry e -> e
  | _ -> fprintf (Format.std_formatter) "%a\n" print_operand op;
    internal "expecting entry"

let rec deep_entry_of_quadop op = match op with
    O_Entry e -> e
  | O_Ref op | O_Deref op -> deep_entry_of_quadop op
  | _ -> internal "not an entry"

(* Make quad labels consequent *)

let normalizeQuads quads =
  let map = Array.make (Label.nextLabel()) 0 in
  let quads1 = List.mapi (fun i q -> map.(q.label) <- (i+1);
                           { label = i+1;
                             operator = q.operator;
                             arg1 = q.arg1;
                             arg2 = q.arg2;
                             arg3 = q.arg3
                           }) quads
  in
  let rec updateLabel quad = match quad.arg3 with
    | O_Label n -> quad.arg3 <- (O_Label map.(n))
    | _ -> ()
  in
  let temptbl = Hashtbl.copy labelsTbl in
  let _ = Hashtbl.clear labelsTbl in
  let () = Hashtbl.iter (fun lbl _ -> 
      Hashtbl.add labelsTbl map.(lbl) 0) temptbl in
    List.iter updateLabel quads1;
    quads1


let printQuad chan quad =
  fprintf chan "%d:\t %a, %a, %a, %a\n" 
    quad.label print_operator quad.operator 
    print_operand quad.arg1 print_operand quad.arg2 print_operand quad.arg3;
  match quad.operator with
    | Q_Endu -> fprintf chan "\n"
    | _ -> ()

let printQuads chan quads = 
  List.iter (fun q -> fprintf chan "%a" printQuad q) quads

let isBop = function
    Q_Plus | Q_Minus | Q_Mult
  | Q_Div | Q_Mod | Q_Fplus
  | Q_Fminus | Q_Fmult | Q_Fdiv -> true
  | _ -> false 

let isEntry = function
  | O_Entry _ -> true
  | _ -> false

(* this is not physical nor structural equality due to the use
 * of Symbol.scoped_eq. It merely checks if two entries use the same id*)
let rec operand_eq arg1 arg2 =
  match arg1, arg2 with
    | O_Int n, O_Int m -> n = m 
    | O_Float n, O_Float m -> n = m
    | O_Char n, O_Char m -> n = m
    | O_Bool n, O_Bool m -> n = m
    | O_Label n, O_Label m -> n = m
    | O_Str n, O_Str m -> n = m
    | O_Backpatch, O_Backpatch -> true
    | O_Entry e, O_Entry f ->
      Symbol.scoped_eq e f
    | O_Empty, O_Empty -> true
    | O_Ref arg1, O_Ref arg2
    | O_Deref arg1, O_Deref arg2 -> operand_eq arg1 arg2
    | O_Size s, O_Size k -> s = k
    | O_Dims n, O_Dims m -> n = m
    | O_Index xs, O_Index ys -> xs = ys
    | _, _ -> false
