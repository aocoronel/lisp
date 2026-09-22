package example

import "core:log"
import "core:os"
import "parser"

main :: proc() {
	log.Level_Headers = {
		0 ..< 10 = "debug: ",
		10 ..< 20 = "info: ",
		20 ..< 30 = "warn: ",
		30 ..< 40 = "error: ",
		40 ..< 50 = "fatal: ",
	}

	log_opt := log.Options{.Level}
	if os.is_tty(os.stdin) do log_opt += {.Terminal_Color}

	context.logger = log.create_console_logger(opt = log_opt)
	defer log.destroy_console_logger(context.logger)

	contents, err := os.read_entire_file_from_path("example.lisp", context.temp_allocator)
	if err != nil do return

	elements := parser.parse(string(contents[:]), "example.lisp") // err := default_error_handler

	for e in elements {
		parser.print(e)
	}
}
