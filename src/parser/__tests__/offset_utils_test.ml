(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2

let pos line column =
  (* Offset_utils doesn't use `offset`, so we can just stub it out. *)
  Loc.({line; column; offset=0})

(* UTF-8 encoding of code point 0x2028, line separator *)
let line_sep = "\xe2\x80\xa8"
(* UTF-8 encoding of code point 0x2029, paragraph separator *)
let par_sep = "\xe2\x80\xa9"
(* UTF-8 encoding of code point 0x1f603, some form of a smiley *)
let smiley = "\xf0\x9f\x98\x83"

let str_with_smiley = Printf.sprintf "foo %s bar\nbaz\n" smiley

let run ctxt text (line, col) expected_offset =
  let table = Offset_utils.make text in
  let offset = Offset_utils.offset table (pos line col) in
  assert_equal ~ctxt expected_offset offset

class loc_extractor = object(this)
  inherit [Loc.t, Loc.t, unit, unit] Flow_polymorphic_ast_mapper.mapper

  (* Locations built up in reverse order *)
  val mutable locs = []
  method get_locs = locs

  method on_loc_annot loc = locs <- loc::locs
  method on_type_annot = this#on_loc_annot
end

let extract_locs ast =
  let extractor = new loc_extractor in
  let _: (unit, unit) Flow_ast.program = extractor#program ast in
  List.rev (extractor#get_locs)

let tests = "offset_utils" >::: [
  "empty_line" >:: begin fun ctxt ->
    run ctxt
      "foo\n\nbar"
      (3, 0)
      5
  end;
  "first_char" >:: begin fun ctxt ->
    run ctxt
      "foo bar\n"
      (1, 0)
      0
  end;
  "last_char" >:: begin fun ctxt ->
    run ctxt
      "foo bar\n"
      (1, 6)
      6
  end;
  "column_after_last" >:: begin fun ctxt ->
    (* The parser gives us locations where the `end` position is exclusive. Even though the last
     * character of the "foo" token is in column 2, the location of "foo" is given as
     * ((1, 0), (1, 3)). Because of this, we need to make sure we can look up locations that are
     * after the final column of a line, even though these locations don't correspond with an actual
     * character. *)
    run ctxt
      "foo\nbar\n"
      (1, 3)
      3
  end;
  "char_after_last" >:: begin fun ctxt ->
    (* See the comment in the previous test *)
    run ctxt
      "foo\nbar"
      (2, 3)
      7
  end;
  "empty" >:: begin fun ctxt ->
    (* Similar to above, we should be able to get one offset in an empty string *)
    run ctxt
      ""
      (1, 0)
      0
  end;
  "no_last_line_terminator" >:: begin fun ctxt ->
    run ctxt
      "foo bar"
      (1, 6)
      6
  end;
  "multi_line" >:: begin fun ctxt ->
    run ctxt
      "foo\nbar\n"
      (2, 1)
      5
  end;
  "carriage_return" >:: begin fun ctxt ->
    run ctxt
      "foo\rbar\r"
      (2, 1)
      5
  end;
  "windows_line_terminator" >:: begin fun ctxt ->
    run ctxt
      "foo\r\nbar\r\n"
      (2, 1)
      6
  end;
  "unicode_line_separator" >:: begin fun ctxt ->
    (* Each line separator character is 3 bytes. The returned offset reflects that. *)
    run ctxt
      (Printf.sprintf "foo%sbar%s" line_sep line_sep)
      (2, 1)
      7
  end;
  "unicode_paragraph_separator" >:: begin fun ctxt ->
    (* Each line separator character is 3 bytes. The returned offset reflects that. *)
    run ctxt
      (Printf.sprintf "foo%sbar%s" par_sep par_sep)
      (2, 1)
      7
  end;
  "offset_before_multibyte_char" >:: begin fun ctxt ->
    run ctxt
      str_with_smiley
      (1, 3)
      3
  end;
  "offset_of_multibyte_char" >:: begin fun ctxt ->
    (* This is the position of the smiley. The offset should give us the first byte in the
     * character. *)
    run ctxt
      str_with_smiley
      (1, 4)
      4
  end;
  "offset_after_multibyte_char" >:: begin fun ctxt ->
    (* This is the position after the smiley. The offset should reflect the width of the multibyte
     * character (4 bytes in this case). *)
    run ctxt
      str_with_smiley
      (1, 5)
      8
  end;
  "offset_line_after_multibyte_char" >:: begin fun ctxt ->
    run ctxt
      str_with_smiley
      (2, 0)
      13
  end;
  "full_test" >:: begin fun ctxt ->
    (* This tests to make sure that we can find an offset for all real-world locations that the
     * parser can produce, and that I haven't made any incorrect assumptions about edge cases in the
     * rest of the tests. Note that there is no newline at the end of the string -- I found a bug in
     * an initial version which was exposed by not having a final newline character. *)
    let source = "const foo = 4;\nconst bar = foo + 2;" in
    let ast, _ = Parser_flow.program source in
    let all_locs = extract_locs ast in
    let all_positions =
      let open Loc in
      let all_starts = List.map (fun {start;_} -> start) all_locs in
      let all_ends = List.map (fun {_end;_} -> _end) all_locs in
      all_starts @ all_ends
    in
    let offset_table = Offset_utils.make source in
    assert_equal ~ctxt 16 (List.length all_locs);
    (* Just make sure it doesn't crash *)
    List.iter begin fun loc ->
      let _: int = Offset_utils.offset offset_table loc in
      ()
    end all_positions
  end;
]
