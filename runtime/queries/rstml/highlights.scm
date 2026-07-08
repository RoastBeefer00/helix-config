; inherits: rust

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
