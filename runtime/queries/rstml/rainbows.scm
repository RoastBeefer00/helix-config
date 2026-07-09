; inherits: rust

; The < > delimiters are children of open_tag/close_tag, not direct children
; of element_node, so include-children is required for them to count as brackets.
([
   (element_node)
   (self_closing_element_node)
 ] @rainbow.scope
 (#set! rainbow.include-children))

["<" ">" "</" "/>"] @rainbow.bracket
