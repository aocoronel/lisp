#!/usr/bin/env something

// comment
/* comment */

1
1.00
identifier
"string"
'±' '1'
true false

("list" ("list2" . "list3") (+ 1 1))

'foo
#'foo
`(x ,y)
,(x)
,@(x)
#(1 2 3)
#'(foo :bar baz)
#.(+ 1 1)

(defun foo (x &optional y)
  (+ 1 1))
