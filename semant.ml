(* Semantic checking for the Harmonica compiler *)

open Ast

module StringMap = Map.Make(String)

(* Semantic checking of a program. Returns void if successful,
   throws an exception if something is wrong. *)

let check (global_vdecls, functions) =
  (* Raise an exception if the given list has a duplicate *)
  let report_duplicate exceptf list =
    let rec helper = function
	n1 :: n2 :: _ when n1 = n2 -> raise (Failure (exceptf n1))
      | _ :: t -> helper t
      | [] -> ()
    in helper (List.sort compare list)
  in

  (* Raise an exception if a given binding is to a void type *)
  let check_not_void exceptf = function
      (DataType(Void), n) -> raise (Failure (exceptf n))
    | _ -> ()
  in

  (* User-defined types *)
  let user_types = Hashtbl.create 10 in
  let rec resolve_user_type usert =
    (match usert with
       UserType(s) -> (try resolve_user_type (Hashtbl.find user_types s)
                       with Not_found -> raise (Failure ("undefined type " ^ s)))
     | _ -> usert)
  in

  (* Structural type equality *)
  let rec typ_equal t1 t2 = 
    (match (t1, t2) with
       (DataType(p1), DataType(p2)) -> if p1 = Unknown || p2 = Unknown 
                                       then true 
                                       else p1 = p2
     | (Tuple(tlist1), Tuple(tlist2)) -> 
        List.for_all2 typ_equal tlist1 tlist2
     | (List(t1'), List(t2')) -> typ_equal t1' t2'
     | (Channel(t1'), Channel(t2')) -> typ_equal t1' t2'
     | (Struct(name1, _), Struct(name2, _)) -> name1 = name2 (* TODO: ok? *)
     | (UserType(_), UserType(_)) -> 
        typ_equal (resolve_user_type t1) (resolve_user_type t2)
     | (FuncType(tlist1), FuncType(tlist2)) -> 
        List.for_all2 typ_equal tlist1 tlist2
     | _ -> false
    ) in

  (* Raise an exception of the given rvalue type cannot be assigned to
     the given lvalue type *)
  let check_assign lvaluet rvaluet err =
     if typ_equal lvaluet rvaluet then lvaluet else raise err
  in

  (**** Checking Functions Definitions ****)
  let builtins = ["print"; "printb"; "printf"; "printi"] in
  let builtin_duplicates = List.filter (fun fname -> List.mem fname builtins)
                                       (List.map (fun fd -> fd.fname) functions) in
  if List.length builtin_duplicates > 0
  then raise (Failure ("function " ^ 
                         (String.concat ", " builtin_duplicates) ^ 
                           " may not be defined")) else ();

  report_duplicate (fun n -> "duplicate function " ^ n)
    (List.map (fun fd -> fd.fname) functions);

  (* Global variable table *)
  let global_vars = Hashtbl.create 10 in

  (* Function declaration for a named function *)
  Hashtbl.add global_vars "print"
              (FuncType([DataType(Void); DataType(String)]));
  Hashtbl.add global_vars "printb"
              (FuncType([DataType(Void); DataType(Bool)]));
  Hashtbl.add global_vars "printf"
              (FuncType([DataType(Void); DataType(Float)]));
  Hashtbl.add global_vars "printi"
              (FuncType([DataType(Void); DataType(Int)]));

  let get_functype fdecl = FuncType(fdecl.typ :: (List.map fst fdecl.formals)) in
  List.iter (fun fd -> Hashtbl.add global_vars fd.fname (get_functype fd)) 
            functions;

  (* Ensure "main" is defined *)
  ignore (try List.find (fun f -> f.fname = "main") functions
          with Not_found -> raise (Failure ("main function undefined")));

  (* List of all symbol tables in scope *)
  let symbol_tables = ref [global_vars] in

  (* NOTE: inner-scope variable overrides outer-scope variable with same name *)
  let rec type_of_identifier_subr s tables =
    (match tables with
       [] -> raise (Failure ("undeclared identifier " ^ s))
     | table :: tl -> try Hashtbl.find table s
                      with Not_found -> type_of_identifier_subr s tl)
  in

  let type_of_identifier s = type_of_identifier_subr s (!symbol_tables) in
    
  (* Return the type of an expression or throw an exception *)
  let rec expr = function
	    Literal _ -> DataType(Int)
    | BoolLit _ -> DataType(Bool)
    | StringLit _ -> DataType(String)
    | FloatLit _ -> DataType(Float)
    | TupleLit elist -> Tuple (List.map expr elist)
    | ListLit elist as e ->
       let tlist = List.map expr elist in
       if (List.length tlist) = 0
       then List(DataType(Unknown))
       else
         let canon = List.hd tlist in
         if List.for_all (fun t -> t = canon) tlist
         then List(canon)
         else raise (Failure ("inconsistent types in list literal " 
                              ^ string_of_expr e))
    | Id s -> type_of_identifier s
    | Binop(e1, op, e2) as e -> 
       let t1 = expr e1 and t2 = expr e2 in
	     (match op with
          Add | Sub | Mult | Div when t1 = DataType(Int) && t2 = DataType(Int)
                -> DataType(Int)
	        | Equal | Neq when t1 = t2 -> DataType(Bool)
	        | Less | Leq | Greater | Geq when t1 = DataType(Int) && t2 = DataType(Int)
            -> DataType(Bool)
	        | And | Or when t1 = DataType(Bool)&& t2 = DataType(Bool) -> DataType(Bool)
          | _ -> raise (Failure ("illegal binary operator " ^
                                   string_of_typ t1 ^ " " ^ string_of_op op ^ " " ^
                                     string_of_typ t2 ^ " in " ^ string_of_expr e))
       )
    | Unop(op, e) as ex -> 
       let t = expr e in
	     (match op with
	        Neg when t = DataType(Int)  -> DataType(Int)
	      | Not when t = DataType(Bool) -> DataType(Bool)
        | _ -> raise (Failure ("illegal unary operator " ^ string_of_uop op ^
	  		                         string_of_typ t ^ " in " ^ string_of_expr ex)))
    | Noexpr -> DataType(Void)
    | Assign(var, e) as ex -> let lt = type_of_identifier var
                              and rt = expr e in
                              check_assign lt rt (Failure ("illegal assignment " ^ string_of_typ lt ^
				                                                     " = " ^ string_of_typ rt ^ " in " ^ 
				                                                       string_of_expr ex))
    | Call(fname, actuals) as call -> 
       let ftype = type_of_identifier fname in
       (match ftype with
          FuncType(tlist) ->
          let formals = List.tl tlist in
          let ret = List.hd tlist in
          if List.length actuals != List.length formals then
            raise (Failure ("expecting " ^ string_of_int
                                             (List.length formals) ^ " arguments in " ^ string_of_expr call))
          else
            List.iter2 (fun ft e -> 
                         let et = expr e in
                         ignore (check_assign ft et
                                              (Failure ("illegal actual argument found " ^ string_of_typ et ^ " expected " ^ string_of_typ ft ^ " in " ^ string_of_expr e))))
                       formals actuals;
          ret
        | _ -> raise (Failure (fname ^ " is not a function"))
       )
  in

  (*** Checking Global Variables ***)
  let check_bind t name = 
    check_not_void (fun n -> "illegal void variable " ^ n) (t, name);
    let scope_table = List.hd (!symbol_tables) in
    if Hashtbl.mem scope_table name then
      raise (Failure ("redefinition of " ^ name))
    else Hashtbl.add scope_table name t in

  let check_vdecl = function
      Bind(t, name) -> check_bind t name
    | Binass(t, name, e) -> 
       check_bind t name;
       let rtype = expr e in
       ignore (check_assign t rtype 
                            (Failure ("illegal assignment " ^ string_of_typ t ^
				                                " = " ^ string_of_typ rtype ^ " in " ^ 
				                                  string_of_expr e)))
  in
  List.iter check_vdecl global_vdecls;

  (*** Checking Function Contents ***)
  let check_function func =
    List.iter (check_not_void (fun n -> "illegal void formal " ^ n ^
      " in " ^ func.fname)) func.formals;

    report_duplicate (fun n -> "duplicate formal " ^ n ^ " in " ^ func.fname)
      (List.map snd func.formals);

    (* Local variables and formals *)
    let local_vars = Hashtbl.create 10 in
    List.iter (fun (t, name) -> 
                Hashtbl.add local_vars name t) func.formals;
    symbol_tables := local_vars :: (!symbol_tables);

    let check_bool_expr e = if expr e != DataType(Bool)
     then raise (Failure ("expected boolean expression in " ^ string_of_expr e))
     else () in

    (* Verify a statement or throw an exception *)
    let rec stmt = function
	      Block sl -> 
        let rec check_block = function
            [Return _ as s] -> stmt s
          | Return _ :: _ -> raise (Failure "nothing may follow a return")
          | s :: ss ->
             (* New symbol table for new scope *)
             let block_vars = Hashtbl.create 10 in
             symbol_tables := block_vars :: (!symbol_tables);
             stmt s;
             check_block ss;
             symbol_tables := List.tl (!symbol_tables)
          | [] -> ()
        in check_block sl
      | Expr e -> ignore (expr e)
      | Return e -> let t = expr e in if typ_equal t func.typ then () else
         raise (Failure ("return gives " ^ string_of_typ t ^ " expected " ^
                         string_of_typ func.typ ^ " in " ^ string_of_expr e))
           
      | If(p, b1, b2) -> check_bool_expr p; stmt b1; stmt b2
      | For(e1, e2, e3, st) -> ignore (expr e1); check_bool_expr e2;
                               ignore (expr e3); stmt st
      | While(p, s) -> check_bool_expr p; stmt s
      | Typedef(t, s) -> Hashtbl.add user_types s (resolve_user_type t)
      | Vdecl(vd) -> check_vdecl vd
    in

    stmt (Block func.body);
    symbol_tables := List.tl (!symbol_tables);

  in
  List.iter check_function functions
