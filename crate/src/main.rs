use std::path::PathBuf;

use clap::Parser;
use magnus::Ruby;

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Cli {
    spec: PathBuf,
    output: PathBuf,
}

const CODE: &str = include_str!("../../main.rb");

fn ruby_main(ruby: &Ruby) -> Result<(), magnus::Error> {
    let cli = Cli::parse();

    let args = vec![cli.spec, cli.output];
    ruby.define_global_const("ARGV", args)?;

    let _: Option<i64> = ruby.eval(CODE)?;
    Ok(())
}

fn main() {

    magnus::Ruby::init(ruby_main).unwrap();
}
