; ─── rstml-specific ───────────────────────────────────────────────────────────

(doctype_node) @constant

(doctype_node ["<!" ">"] @tag.delimiter)

(open_tag ["<" ">"] @tag.delimiter)

(close_tag ["</" ">"] @tag.delimiter)

(self_closing_element_node ["<" "/>"] @tag.delimiter)

(node_identifier ["-" ":" "::"] @punctuation.delimiter)

(open_tag name: (node_identifier) @tag)

(close_tag name: (node_identifier) @tag)

(self_closing_element_node name: (node_identifier) @tag)

(node_attribute name: (node_identifier) @tag.attribute)

(node_attribute value: (rust_expression (string_literal) @string))
(node_attribute value: (rust_expression (raw_string_literal) @string))

(text_node) @string

(comment_node ["<!--" "-->"] @comment)
(comment_node) @comment

; ─── Rust expression highlights (rstml embeds Rust exprs, not type decls) ─────
; Inlined from runtime/queries/rust/highlights.scm minus nodes absent in rstml:
;   type_parameter, array_type, shebang, gen_block

"?" @special

(type_identifier) @type
(identifier) @variable
(field_identifier) @variable.other.member

[
  "*"
  "'"
  "->"
  "=>"
  "<="
  "="
  "=="
  "!"
  "!="
  "%"
  "%="
  "&"
  "&="
  "&&"
  "|"
  "|="
  "||"
  "^"
  "^="
  "*="
  "-"
  "-="
  "+"
  "+="
  "/"
  "/="
  ">"
  "<"
  ">="
  ">>"
  "<<"
  ">>="
  "<<="
  "@"
  ".."
  "..="
  "..."
  "'"
] @operator

(use_declaration argument: (identifier) @namespace)
(use_wildcard (identifier) @namespace)
(extern_crate_declaration name: (identifier) @namespace alias: (identifier)? @namespace)
(mod_item name: (identifier) @namespace)
(scoped_use_list path: (identifier)? @namespace)
(use_list (identifier) @namespace)
(use_as_clause path: (identifier)? @namespace alias: (identifier) @namespace)

; type_parameter omitted — not present in rstml grammar
((type_arguments (type_identifier) @constant) (#match? @constant "^[A-Z_]+$"))
(type_arguments (type_identifier) @type)
("_" @comment.unused)
((type_arguments (type_identifier) @comment.unused) (#eq? @comment.unused "_"))
; array_type omitted — not present in rstml grammar

(escape_sequence) @constant.character.escape
(primitive_type) @type.builtin
(boolean_literal) @constant.builtin.boolean
(integer_literal) @constant.numeric.integer
(float_literal) @constant.numeric.float
(char_literal) @constant.character
[
  (string_literal)
  (raw_string_literal)
] @string

; shebang omitted — not present in rstml grammar
(line_comment) @comment.line
(block_comment) @comment.block

(self) @variable.builtin

(field_initializer (field_identifier) @variable.other.member)
(shorthand_field_initializer (identifier) @variable.other.member)
(shorthand_field_identifier) @variable.other.member

(lifetime "'" @label (identifier) @label)
(label "'" @label (identifier) @label)

[
  "::"
  "."
  ";"
  ","
  ":"
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
  "#"
] @punctuation.bracket
(type_arguments ["<" ">"] @punctuation.bracket)
(type_parameters ["<" ">"] @punctuation.bracket)
(for_lifetimes ["<" ">"] @punctuation.bracket)
(closure_parameters "|" @punctuation.bracket)
(bracketed_type ["<" ">"] @punctuation.bracket)

(let_declaration
  pattern: [
    ((identifier) @variable)
    ((tuple_pattern (identifier) @variable))
  ])

(_ value: (field_expression value: (identifier)? @variable field: (field_identifier) @variable.other.member))

(parameter pattern: (identifier) @variable.parameter)
(closure_parameters (identifier) @variable.parameter)

(let_declaration (mutable_specifier) pattern: (identifier) @variable.mutable)
(mut_pattern (mutable_specifier) (identifier) @variable.mutable)
(parameter (mutable_specifier) pattern: (identifier) @variable.parameter.mutable)
(self_parameter (mutable_specifier) (self) @variable.builtin.mutable)

"in" @keyword.control

[
  "match"
  "if"
  "else"
  "try"
] @keyword.control.conditional

[
  "while"
  "loop"
] @keyword.control.repeat

[
  "break"
  "continue"
  "return"
  "await"
  "yield"
] @keyword.control.return

"use" @keyword.control.import
(mod_item "mod" @keyword.control.import !body)
(use_as_clause "as" @keyword.control.import)

(type_cast_expression "as" @keyword.operator)

[
  (crate)
  (super)
  "as"
  "pub"
  "mod"
  "extern"
  "impl"
  "where"
  "trait"
  "for"
  "default"
  "async"
] @keyword

(for_expression "for" @keyword.control.repeat)
; gen_block omitted — not present in rstml grammar

[
  "struct"
  "enum"
  "union"
  "type"
] @keyword.storage.type

"let" @keyword.storage
"fn" @keyword.function
"unsafe" @keyword.storage.modifier
"macro_rules!" @function.macro

(mutable_specifier) @keyword.storage.modifier.mut

(reference_type "&" @keyword.storage.modifier.ref)
(self_parameter "&" @keyword.storage.modifier.ref)

[
  "static"
  "const"
  "ref"
  "move"
  "dyn"
] @keyword.storage.modifier

(scoped_identifier path: (identifier)? @namespace name: (identifier) @namespace)
(scoped_type_identifier path: (identifier) @namespace)

(call_expression
  function: _
  arguments: (arguments (scoped_identifier path: _ name: (identifier) @function)))

(call_expression
  function: [
    ((identifier) @function)
    (scoped_identifier name: (identifier) @function)
    (field_expression field: (field_identifier) @function.method)
  ])
(generic_function
  function: [
    ((identifier) @function)
    (scoped_identifier name: (identifier) @function)
    (field_expression field: (field_identifier) @function.method)
  ])

(function_item name: (identifier) @function)
(function_signature_item name: (identifier) @function)

((identifier) @type (#match? @type "^[A-Z]"))
(never_type "!" @type)
((identifier) @constant (#match? @constant "^[A-Z][A-Z\\d_]*$"))

(call_expression
  function: [
    ((identifier) @constructor (#match? @constructor "^[A-Z]"))
    (scoped_identifier name: ((identifier) @constructor (#match? @constructor "^[A-Z]")))
  ])

(field_expression
  value: (scoped_identifier
    path: [(identifier) @type (scoped_identifier name: (identifier) @type)]
    name: (identifier) @constructor
    (#match? @type "^[A-Z]")
    (#match? @constructor "^[A-Z]")))

(enum_variant (identifier) @type.enum.variant)

(struct_expression name: (type_identifier) @constructor)

(tuple_struct_pattern
  type: [
    (identifier) @constructor
    (scoped_identifier name: (identifier) @constructor)
  ])
(struct_pattern
  type: [
    ((type_identifier) @constructor)
    (scoped_type_identifier name: (type_identifier) @constructor)
  ])
(match_pattern ((identifier) @constructor) (#match? @constructor "^[A-Z]"))
(or_pattern
  ((identifier) @constructor)
  ((identifier) @constructor)
  (#match? @constructor "^[A-Z]"))

(match_pattern
  (scoped_identifier
    path: [(identifier) @type (scoped_identifier name: (identifier) @type)]
    name: (identifier) @type.enum.variant
    (#match? @type "^[A-Z]")
    (#match? @type.enum.variant "^[A-Z]")))

(match_pattern
  (struct_pattern
    type: (scoped_type_identifier
      path: [(identifier) @type (scoped_identifier name: (identifier) @type)]
      name: (type_identifier) @type.enum.variant
      (#match? @type "^[A-Z]")
      (#match? @type.enum.variant "^[A-Z]"))))

(match_pattern
  (tuple_struct_pattern
    type: (scoped_identifier
      path: [(identifier) @type (scoped_identifier name: (identifier) @type)]
      name: (identifier) @type.enum.variant
      (#match? @type "^[A-Z]")
      (#match? @type.enum.variant "^[A-Z]"))))

(match_pattern (scoped_identifier name: (identifier) @constant (#match? @constant "^[A-Z_]+$")))

(attribute (identifier) @function.macro)
(inner_attribute_item "!" @punctuation)
(attribute
  [
    (identifier) @function.macro
    (scoped_identifier name: (identifier) @function.macro)
  ]
  (token_tree (identifier) @function.macro)?)

(inner_attribute_item) @attribute

(macro_definition name: (identifier) @function.macro)
(macro_invocation
  macro: [
    ((identifier) @function.macro)
    (scoped_identifier name: (identifier) @function.macro)
  ]
  "!" @function.macro)

(metavariable) @variable.parameter
(fragment_specifier) @type
