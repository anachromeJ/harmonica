(* Semantic checking for the Harmonica compiler *)

open Ast

module StringMap = Map.Make(String)

(* Semantic checking of a program. Returns void if successful,
   throws an exception if something is wrong.

   Check each global variable, then check each function *)

let check (global_vdecls, functions) =

  let vdecl_to_bind = function
      Bind(t, n) -> (t, n)
    | Binass(t, n, _) -> (t, n)
  in

  let global_binds = List.map vdecl_to_bind global_vdecls in

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

  (**** Checking Global Variables ****)

  List.iter (check_not_void (fun n -> "illegal void global " ^ n)) global_binds;
  report_duplicate (fun n -> "duplicate global " ^ n) (List.map snd global_binds);

  (**** Checking Functions ****)

  if List.mem "print" (List.map (fun fd -> fd.fname) functions)
  then raise (Failure ("function print may not be defined")) else ();

  report_duplicate (fun n -> "duplicate function " ^ n)
    (List.map (fun fd -> fd.fname) functions);

  (* User-defined types *)
  let user_types = Hashtbl.create 10 in
  let rec resolve_user_type usert =
    (match usert with
       UserType(s) -> (try resolve_user_type (Hashtbl.find user_types s)
                       with Not_found -> raise (Failure ("undefined type " ^ s)))
     | _ -> usert)
  in

  (* Structural equality *)
  let rec typ_equal t1 t2 = 
    (match (t1, t2) with
       (DataType(p1), DataType(p2)) -> p1 == p2
     | (Tuple(tlist1), Tuple(tlist2)) -> 
        List.for_all2 typ_equal tlist1 tlist2
     | (List(t1'), List(t2')) -> typ_equal t1' t2'
     | (Channel(t1'), Channel(t2')) -> typ_equal t1' t2'
     | (Struct(name1, _), Struct(name2, _)) -> name1 == name2 (* TODO: ok? *)
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

  (* Global variable table *)
  let global_vars = Hashtbl.create 10 in
  List.iter (fun (t, name) -> Hashtbl.add global_vars name t) global_binds;

  (* Function declaration for a named function *)
  let built_in_decls =  StringMap.singleton "print"
     { typ = DataType(Void); fname = "print"; formals = [(DataType(String), "x")];
       body = [] }
   in

  let function_decls = List.fold_left (fun m fd -> StringMap.add fd.fname fd m)
                         built_in_decls functions
  in

  let function_decl s = try StringMap.find s function_decls
       with Not_found -> raise (Failure ("unrecognized function " ^ s))
  in

  let _ = function_decl "main" in (* Ensure "main" is defined *)

  let check_function func =

    List.iter (check_not_void (fun n -> "illegal void formal " ^ n ^
      " in " ^ func.fname)) func.formals;

    report_duplicate (fun n -> "duplicate formal " ^ n ^ " in " ^ func.fname)
      (List.map snd func.formals);

    (* Local variables and formals *)
    let local_vars = Hashtbl.create 10 in
    List.iter (fun (t, name) -> Hashtbl.add local_vars name t) func.formals;
    
    (* NOTE: local variable overrides global variable with same name *)
    let type_of_identifier s =
      try Hashtbl.find local_vars s
      with Not_found -> 
        try Hashtbl.find global_vars s
        with Not_found -> raise (Failure ("undeclared identifier " ^ s))
    in

    let check_bind t name = if Hashtbl.mem local_vars name then
                              raise (Failure ("redefinition of " ^ name))
                            else Hashtbl.add local_vars name t in

    (* Return the type of an expression or throw an exception *)
    let rec expr = function
	      Literal _ -> DataType(Int)
      | BoolLit _ -> DataType(Bool)
      | StringLit _ -> DataType(String)
      | FloatLit _ -> DataType(Float)
      | TupleLit elist -> Tuple (List.map expr elist)
      | ListLit elist as e ->
         (* TODO: type of empty lists (unknown?) *)
         let tlist = List.map expr elist in
         if (List.length tlist) == 0
         then raise (Failure ("not yet implemented"))
         else
           let canon = List.hd tlist in
           if List.for_all (fun t -> t == canon) tlist
           then List(canon)
           else raise (Failure ("inconsistent types in list literal " ^ string_of_expr e))
      | Id s -> type_of_identifier s
      | Binop(e1, op, e2) as e -> 
         let t1 = expr e1 and t2 = expr e2 in
	       (match op with
            Add | Sub | Mult | Div when t1 =DataType(Int)&& t2 =DataType(Int)->DataType(Int)
	          | Equal | Neq when t1 = t2 ->DataType(Bool)
	          | Less | Leq | Greater | Geq when t1 =DataType(Int)&& t2 =DataType(Int)->DataType(Bool)
	          | And | Or when t1 =DataType(Bool)&& t2 =DataType(Bool)->DataType(Bool)
            | _ -> raise (Failure ("illegal binary operator " ^
                                     string_of_typ t1 ^ " " ^ string_of_op op ^ " " ^
                                       string_of_typ t2 ^ " in " ^ string_of_expr e))
         )
      | Unop(op, e) as ex -> 
         let t = expr e in
	       (match op with
	          Neg when t =DataType(Int)->DataType(Int)
	        | Not when t =DataType(Bool)->DataType(Bool)
          | _ -> raise (Failure ("illegal unary operator " ^ string_of_uop op ^
	  		                           string_of_typ t ^ " in " ^ string_of_expr ex)))
      | Noexpr -> DataType(Void)
      | Assign(var, e) as ex -> let lt = type_of_identifier var
                                and rt = expr e in
                                check_assign lt rt (Failure ("illegal assignment " ^ string_of_typ lt ^
				                                                       " = " ^ string_of_typ rt ^ " in " ^ 
				                                                         string_of_expr ex))
      | Call(fname, actuals) as call -> 
         let fd = function_decl fname in
         if List.length actuals != List.length fd.formals then
           raise (Failure ("expecting " ^ string_of_int
             (List.length fd.formals) ^ " arguments in " ^ string_of_expr call))
         else
           List.iter2 (fun (ft, _) e -> let et = expr e in
              ignore (check_assign ft et
                (Failure ("illegal actual argument found " ^ string_of_typ et ^
                " expected " ^ string_of_typ ft ^ " in " ^ string_of_expr e))))
             fd.formals actuals;
           fd.typ
    in

    let check_bool_expr e = if expr e !=DataType(Bool)
     then raise (Failure ("expectedDataType(Bool)ean expression in " ^ string_of_expr e))
     else () in

    (* Verify a statement or throw an exception *)
    let rec stmt = function
	      Block sl -> 
        (* TODO: Block-level scoping *)
        let rec check_block = function
            [Return _ as s] -> stmt s
          | Return _ :: _ -> raise (Failure "nothing may follow a return")
          | Block sl :: ss -> check_block (sl @ ss)
          | s :: ss -> stmt s ; check_block ss
          | [] -> ()
        in check_block sl
      | Expr e -> ignore (expr e)
      | Return e -> let t = expr e in if t = func.typ then () else
         raise (Failure ("return gives " ^ string_of_typ t ^ " expected " ^
                         string_of_typ func.typ ^ " in " ^ string_of_expr e))
           
      | If(p, b1, b2) -> check_bool_expr p; stmt b1; stmt b2
      | For(e1, e2, e3, st) -> ignore (expr e1); check_bool_expr e2;
                               ignore (expr e3); stmt st
      | While(p, s) -> check_bool_expr p; stmt s
      | Typedef(t, s) -> Hashtbl.add user_types s (resolve_user_type t)
      | Vdecl(vd) ->
         (match vd with
            Bind(t, name) -> check_bind t name
          | Binass(t, name, e) -> 
             check_bind t name;
             let rtype = expr e in
             ignore (check_assign t rtype 
                                  (Failure ("illegal assignment " ^ string_of_typ t ^
				                                      " = " ^ string_of_typ rtype ^ " in " ^ 
				                                        string_of_expr e))))
    in

    stmt (Block func.body)
   
  in
  List.iter check_function functions
