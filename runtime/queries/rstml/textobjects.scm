; Tag text objects for rstml (Leptos view! macros), mirroring helix's HTML
; xml-element textobject so cit/cat/dit/dat/yit/yat/vit/vat work inside view!.

(element_node (open_tag) (_)* @xml-element.inside (close_tag)) @xml-element.around

(element_node) @xml-element.around

(self_closing_element_node) @xml-element.around @xml-element.inside

(comment_node) @comment.around
