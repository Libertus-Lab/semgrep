(* Yoann Padioleau
 *
 * Copyright (C) 2010 Facebook
 * Copyright (C) 2023 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common
open Sexplib.Std

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Information about tokens (mostly their location).
 *
 * Note that Tok.t below is a bit complicated because we want
 * to represent "fake" and "expanded" tokens. The type used to be even
 * more complicated to allow to annotate tokens with transformation information
 * for Spatch in Coccinelle. However, this is not the case anymore because
 * we use a different approach to transform code
 * (AST-based autofix in Semgrep).
 *
 * We use fake tokens because in many of
 * the ASTs/CSTs in Semgrep (including in AST_generic.ml) we store the
 * tokens in the ASTs/CSTs at the leaves, and sometimes the actual
 * token is optional (e.g., a virtual semicolon in Javascript). Moreover,
 * we abuse those tokens at the leaves to compute the range of constructs.
 * Finally those tokens are convenient for precise error reporting.
 * alt:
 *   - we could use cleaner ASTs with range (general location) information at
 *     every nodes, in which case we would not need at least the fake
 *     tokens (we might still need the ExpandedTok type construct though).
 *   - we could also use more 'Tok.t option' instead of using fake tokens.
 *
 * Technically speaking, 't' below is not really a token, because the type does
 * not store the kind of the token (e.g., PLUS | IDENT | IF | ...), just its
 * content. It's really just a lexeme, but the word lexeme is not as
 * known as token.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* To report errors, regular position information.
 * Note that Loc.t is now an alias for Tok.location.
 *)
type location = {
  (* the content of the "token" *)
  str : string;
  (* TODO? the content of Pos.t used to be inlined in this location type.
   * It is cleaner to factorize things in Pos.t, but this introduces
   * an extra pointer which actually can have real performance implication
   * in Semgrep on huge monorepos. It might be worth inlining it back
   * (and also reduce its number of fields).
   *)
  pos : Pos.t;
}
[@@deriving show { with_path = false }, eq, ord, sexp]

(* to represent fake (e.g., fake semicolons in languages such as Javascript),
 * and expanded tokens (e.g., preprocessed constructs by cpp for C/C++)
 *)
type t =
  (* Present both in the AST and list of tokens in the pfff-based parsers *)
  | OriginTok of location
  (* Present only in the AST and generated after parsing. Can be used
   * when building some extra AST elements.
   * The string (e.g., ";")  is to help the generic pretty printer.
   * TODO: we should remove the option below and enforce the construction
   * of safe fake tokens.
   *)
  | FakeTok of string * virtual_location option
  (* In the case of a XHP file, we could preprocess it and incorporate
   * the tokens of the preprocessed code with the tokens from
   * the original file. We want to mark those "expanded" tokens
   * with a special tag so that if someone do some transformation on
   * those expanded tokens they will get a warning (because we may have
   * trouble back-propagating the transformation back to the original file).
   * The location refers to the preprocessed file (e.g. /tmp/pp-xxxx.pphp).
   *)
  | ExpandedTok of location * virtual_location
  (* The Ab constructor is (ab)used to call '=' to compare
   * big AST portions. Indeed as we keep the token information in the AST,
   * if we have an expression in the code like "1+1" and want to test if
   * it's equal to another code like "1+1" located elsewhere, then
   * the Pervasives.'=' of OCaml will not return true because
   * when it recursively goes down to compare the leaf of the AST, that is
   * the token_location, there will be some differences of positions. If instead
   * all leaves use Ab, then there is no position information and we can
   * use '='. See also the 'al_info' function below.
   *
   * Ab means AbstractLineTok. I Use a short name to not
   * polluate in debug mode.
   *
   * update: this constructor is not that useful anymore; You should prefer to
   * use t_always_equal instead to compare big AST elements and not care
   * about position.
   *)
  | Ab

(* Sometimes we generate fake tokens close to existing
 * origin tokens. This can be useful when we need to give an error
 * message that involves a fakeToken. The int below is a kind of
 * virtual position, an offset.
 * Those are called "safe" fake tokens (in contrast to the
 * regular/unsafe one which have no position information at all).
 *
 * For ExpandedTok the location refers to the last token
 * before a series of expanded tokens and the int is an offset.
 * The goal is to be able to compare the position of tokens,
 * even for expanded tokens. See compare_pos().
 *)
and virtual_location = location * int
[@@deriving show { with_path = false }, eq, ord, sexp]

type t_always_equal = t [@@deriving show, sexp]

(* sgrep: we do not care about position when comparing for equality 2 ASTs.
 * related: Lib_AST.abstract_position_info_any and then use OCaml generic '='.
 *)
let equal_t_always_equal _t1 _t2 = true
let hash_t_always_equal _t = 0
let hash_fold_t_always_equal acc _t = acc

exception NoTokenLocation of string

(*****************************************************************************)
(* Dumpers *)
(*****************************************************************************)

(* see also -full_token_info in Meta_AST.ml *)
let pp_full_token_info = ref false

(* for ppx_deriving *)
let pp fmt t = if !pp_full_token_info then pp fmt t else Format.fprintf fmt "()"

(* not sure why we also need to define this one, but without this
 * semgrep-core -diff_pfff_tree_sitter, which uses AST_generic.show_program,
 * always display the full token info of the token
 *)
let pp_t_always_equal fmt t =
  if !pp_full_token_info then pp fmt t else Format.fprintf fmt "()"

(*****************************************************************************)
(* Fake tokens (safe and unsafe) *)
(*****************************************************************************)

let is_fake tok =
  match tok with
  | FakeTok _ -> true
  | _ -> false

let is_origintok ii =
  match ii with
  | OriginTok _ -> true
  | _ -> false

let fake_location = { str = ""; pos = Pos.fake_pos }

(* Synthesize a fake token *)
let unsafe_fake_tok str : t = FakeTok (str, None)

(* Synthesize a "safe" fake token *)
let fake_tok_loc next_to_loc str : t =
  (* TODO: offset seems to have no use right now (?) *)
  FakeTok (str, Some (next_to_loc, -1))

let loc_of_tok (ii : t) : (location, string) Result.t =
  match ii with
  | OriginTok pinfo -> Ok pinfo
  (* TODO ? dangerous ? *)
  | ExpandedTok (pinfo_pp, _) -> Ok pinfo_pp
  | FakeTok (_, Some (pi, _)) -> Ok pi
  | FakeTok (_, None) -> Error "FakeTok"
  | Ab -> Error "Ab"

let fake_tok next_to_tok str : t =
  match loc_of_tok next_to_tok with
  | Ok loc -> fake_tok_loc loc str
  | Error _ -> unsafe_fake_tok str

(* TODO? the use of unsafe_fake_xxx is usually because the token
 * does not exist in the original file. It's better then to generate
 * an empty string in the FakeTokStr so that pretty printer will
 * not generate those brackets or semicolons. Moreover
 * we use unsafe_fake_bracket not only for () but also for [], {}, and
 * now even for "", so better again to put an empty string in it?
 *)

let unsafe_sc = unsafe_fake_tok ";"
let sc next_to_tok = fake_tok next_to_tok ";"

let fake_bracket next_to_tok x =
  (fake_tok next_to_tok "(", x, fake_tok next_to_tok ")")

(* used to be in AST_generic.ml *)
let unsafe_fake_bracket x = (unsafe_fake_tok "(", x, unsafe_fake_tok ")")

(*****************************************************************************)
(* Accessors *)
(*****************************************************************************)

let stringpos_of_tok (x : t) : string =
  match loc_of_tok x with
  | Ok loc -> Pos.string_of_pos loc.pos
  | Error msg -> spf "unknown location (%s)" msg

let unsafe_loc_of_tok ii =
  match loc_of_tok ii with
  | Ok pinfo -> pinfo
  | Error msg -> raise (NoTokenLocation msg)

let line_of_tok ii = (unsafe_loc_of_tok ii).pos.line
let col_of_tok ii = (unsafe_loc_of_tok ii).pos.column

(* todo: return a Real | Virt position ? *)
let bytepos_of_tok ii = (unsafe_loc_of_tok ii).pos.bytepos
let file_of_tok ii = (unsafe_loc_of_tok ii).pos.file

let content_of_tok ii =
  match ii with
  | OriginTok x -> x.str
  | FakeTok (s, _) -> s
  | ExpandedTok _
  | Ab ->
      raise (NoTokenLocation "content_of_tok: Expanded or Ab")

let content_of_tok_opt ii =
  match ii with
  | OriginTok x -> Some x.str
  | FakeTok (s, _) -> Some s
  | ExpandedTok _
  | Ab ->
      None

(* Token locations are supposed to denote the beginning of a token.
   Suppose we are interested in instead having line, column, and bytepos of
   the end of a token instead.
   This is something we can do at relatively low cost by going through and
   inspecting the contents of the token, plus the start information.
*)
let end_pos_of_loc loc =
  let line, col, trailing_nl =
    String.fold_left
      (fun (line, col, after_nl) c ->
        match c with
        | '\n' when after_nl -> (line + 1, 0, true)
        | '\n' -> (line, col, true)
        | _ when after_nl -> (line + 1, 1, false)
        | _ -> (line, col + 1, false))
      (loc.pos.line, loc.pos.column, false)
      loc.str
  in
  let col =
    (* THINK: We count a trailing newline as an extra character in the last line,
     * is that the standard ? *)
    if trailing_nl then col + 1 else col
  in
  (line, col, loc.pos.bytepos + String.length loc.str)

(*****************************************************************************)
(* Builders *)
(*****************************************************************************)

let tok_of_loc loc = OriginTok loc

let tok_of_str_and_bytepos str pos =
  let loc =
    {
      str;
      (* the pos will be filled in post-lexing phase, see complete_location *)
      pos = Pos.make pos;
    }
  in
  tok_of_loc loc

let tok_of_lexbuf lexbuf =
  tok_of_str_and_bytepos (Lexing.lexeme lexbuf) (Lexing.lexeme_start lexbuf)

let first_loc_of_file file = { str = ""; pos = Pos.first_pos_of_file file }
let first_tok_of_file file = fake_tok_loc (first_loc_of_file file) ""

let rewrap_str s ii =
  match ii with
  | OriginTok pi -> OriginTok { pi with str = s }
  | FakeTok (s, info) -> FakeTok (s, info)
  | Ab -> Ab
  | ExpandedTok _ ->
      (* ExpandedTok ({ pi with Common.str = s;},vpi) *)
      failwith "rewrap_str: ExpandedTok not allowed here"

(* less: should use Buffer and not ^ so we should not need that *)
let tok_add_s s ii = rewrap_str (content_of_tok ii ^ s) ii

let str_of_info_fake_ok ii =
  match ii with
  | OriginTok pinfo -> pinfo.str
  | ExpandedTok (pinfo_pp, _vloc) -> pinfo_pp.str
  | FakeTok (_, Some (pi, _)) -> pi.str
  | FakeTok (s, None) -> s
  | Ab -> raise (NoTokenLocation "Ab")

let combine_toks x xs =
  let str = xs |> List.map str_of_info_fake_ok |> String.concat "" in
  tok_add_s str x

let empty_tok_after tok : t =
  match loc_of_tok tok with
  | Ok loc ->
      let prev_len = String.length loc.str in
      let loc =
        {
          str = "";
          pos =
            {
              loc.pos with
              bytepos = loc.pos.bytepos + prev_len;
              column = loc.pos.column + prev_len;
            };
        }
      in
      tok_of_loc loc
  | Error _ -> rewrap_str "" tok

let combine_bracket_contents (open_, xs, _close) =
  let toks = List_.map snd xs in
  match toks with
  | x :: xs -> combine_toks x xs
  | [] -> empty_tok_after open_

let split_tok_at_bytepos pos ii =
  let loc = unsafe_loc_of_tok ii in
  let str = loc.str in
  let loc1_str = String.sub str 0 pos in
  let loc2_str = String.sub str pos (String.length str - pos) in
  let loc1 = { loc with str = loc1_str } in
  let loc2 =
    {
      str = loc2_str;
      pos =
        {
          loc.pos with
          bytepos = loc.pos.bytepos + pos;
          column = loc.pos.column + pos;
        };
    }
  in
  (tok_of_loc loc1, tok_of_loc loc2)

(*****************************************************************************)
(* Adjusting location *)
(*****************************************************************************)

(* TODO? move to Pos.ml and use Pos.t instead *)
let adjust_loc_wrt_base base_loc loc =
  (* Note that bytepos and columns are 0-based, whereas lines are 1-based. *)
  let base_pos = base_loc.pos in
  let pos = loc.pos in
  {
    loc with
    pos =
      {
        bytepos = base_pos.bytepos + pos.bytepos;
        line = base_pos.line + pos.line - 1;
        column =
          (if pos.line =|= 1 then base_pos.column + pos.column else pos.column);
        file = base_pos.file;
      };
  }

let fix_location fix ii =
  match ii with
  | OriginTok pi -> OriginTok (fix pi)
  | ExpandedTok (pi, vloc) -> ExpandedTok (fix pi, vloc)
  | FakeTok (s, vloc_opt) -> FakeTok (s, vloc_opt)
  | Ab -> Ab

let adjust_tok_wrt_base base_loc ii =
  fix_location (adjust_loc_wrt_base base_loc) ii

let fix_pos fix loc = { loc with pos = fix loc.pos }

(*****************************************************************************)
(* Adjust line x col *)
(*****************************************************************************)

let complete_location filename table (x : location) =
  { x with pos = Pos.complete_position filename table x.pos }

(*
I used to have:
 type program2 = toplevel2 list
  (* the token list contains also the comment-tokens *)
  and toplevel2 = Ast_php.toplevel * Parser_php.token list
type program_with_comments = program2

and a function below called distribute_info_items_toplevel that
would distribute the list of tokens to each toplevel entity.
This was when I was storing parts of AST in berkeley DB and when
I wanted to get some information about an entity (a function, a class)
I wanted to get the list also of tokens associated with that entity.

Now I just have
 type program_and_tokens = Ast_php.program * Parser_php.token list
because I don't use berkeley DB. I use codegraph and an entity_finder
we just focus on use/def and does not store huge asts on disk.


let rec distribute_info_items_toplevel2 xs toks filename =
  match xs with
  | [] -> raise Impossible
  | [Ast_php.FinalDef e] ->
      (* assert (null toks) ??? no cos can have whitespace tokens *)
      let info_item = toks in
      [Ast_php.FinalDef e, info_item]
  | ast::xs ->

      (match ast with
      | Ast_js.St (Ast_js.Nop None) ->
          distribute_info_items_toplevel2 xs toks filename
      | _ ->


      let ii = Lib_parsing_php.ii_of_any (Ast.Toplevel ast) in
      (* ugly: I use a fakeInfo for lambda f_name, so I have
       * have to filter the abstract info here
       *)
      let ii = List.filter PI.is_origintok ii in
      let (min, max) = PI.min_max_ii_by_pos ii in

      let toks_before_max, toks_after =
(* on very huge file, this function was previously segmentation fault
 * in native mode because span was not tail call
 *)
        Common.profile_code "spanning tokens" (fun () ->
        toks +> Common2.span_tail_call (fun tok ->
          match PI.compare_pos (TH.info_of_tok tok) max with
          | -1 | 0 -> true
          | 1 -> false
          | _ -> raise Impossible
        ))
      in
      let info_item = toks_before_max in
      (ast, info_item)::distribute_info_items_toplevel2 xs toks_after filename

let distribute_info_items_toplevel a b c =
  Common.profile_code "distribute_info_items" (fun () ->
    distribute_info_items_toplevel2 a b c
  )
 *)

(*****************************************************************************)
(* Compare *)
(*****************************************************************************)

(* not used but used to be useful in coccinelle *)
type posrv =
  | Real of location
  | Virt of
      location (* last real info before expanded tok *)
      * int (* virtual offset *)

let compare_pos ii1 ii2 =
  let get_pos = function
    | OriginTok pi -> Real pi
    (* todo? I have this for lang_php/
        | FakeTok (s, Some (pi_orig, offset)) ->
            Virt (pi_orig, offset)
    *)
    | FakeTok _ -> raise (NoTokenLocation "compare_pos: FakeTok")
    | Ab -> raise (NoTokenLocation "compare_pos: Ab")
    | ExpandedTok (_pi_pp, (pi_orig, offset)) -> Virt (pi_orig, offset)
  in
  let pos1 = get_pos ii1 in
  let pos2 = get_pos ii2 in
  match (pos1, pos2) with
  | Real p1, Real p2 -> Int.compare p1.pos.bytepos p2.pos.bytepos
  | Virt (p1, _), Real p2 ->
      if Int.compare p1.pos.bytepos p2.pos.bytepos =|= -1 then -1 else 1
  | Real p1, Virt (p2, _) ->
      if Int.compare p1.pos.bytepos p2.pos.bytepos =|= 1 then 1 else -1
  | Virt (p1, o1), Virt (p2, o2) -> (
      let poi1 = p1.pos.bytepos in
      let poi2 = p2.pos.bytepos in
      match Int.compare poi1 poi2 with
      | -1 -> -1
      | 0 -> Int.compare o1 o2
      | 1 -> 1
      | _ -> raise Impossible)

(*****************************************************************************)
(* Other helpers *)
(*****************************************************************************)

let unbracket (_, x, _) = x

(* used only in the Scala parser for now *)
let abstract_tok = Ab
