use std::process::ExitCode;

fn main() -> ExitCode {
    telepatch::cli::main(&tp_basic::playbooks())
}
